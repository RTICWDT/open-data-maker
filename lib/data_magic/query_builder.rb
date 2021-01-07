require 'json'

require_relative './nested_query_builder'

module DataMagic
  module QueryBuilder
    class << self
      @@dictionary ||= {}

      def set_dictionary(config)
        @@dictionary = config.dictionary
      end 

      # Creates query from parameters passed into endpoint and returns a Hash
      def from_params(params, options, config)
        set_dictionary(config)
        per_page = (options[:per_page] || config.page_size || DataMagic::DEFAULT_PAGE_SIZE).to_i
        page = options[:page].to_i || 0
        per_page = DataMagic::MAX_PAGE_SIZE if per_page > DataMagic::MAX_PAGE_SIZE

        query_hash = {
          post_es_response: {},
          from:             page * per_page,
          size:             per_page,
        }

        # check options[:fields] - are any nested data type?
        nested_fields = !options[:fields].nil? ? nested_fields(options[:fields]) : []
        query_fields  = !options[:fields].nil? ? options[:fields] - nested_fields : []

        original_params = params.clone()

        # check params keys - are any nested data type?
        term_pairs = determine_query_term_datatypes(params)
        nested_query_pairs = term_pairs[:nested_query_pairs]
        query_pairs        = term_pairs[:query_pairs]

        all_programs_nested = options[:all_programs_nested]
        if !all_programs_nested && options[:all_programs]
          all_programs = options[:all_programs]
        end 

        # Use stretchy to build query
        if all_programs
          # Treat all query fields as standard data types, rather than nested datatypes
          squery = generate_squery(original_params, options, config)
        else
          # Only pass standard data types to squery generator function
          squery = generate_squery(query_pairs, options, config)
        end
        query_hash[:query] = squery.request[:body][:query]

        nested_query = false
        if !all_programs && !nested_query_pairs.empty?
          nested_query = true

          query_hash = NestedQueryBuilder.integrate_query_pairs(nested_query_pairs, query_hash, query_pairs)
        end

        if !query_fields.empty?
          query_hash[:fields] = query_fields
        end

        query_hash[:query].except!(:match_all) unless query_hash[:query][:bool].nil?

        # TODO - Revisit ./spec/lib/data_magic/query_builder_spec.rb:28
        # That test broke, when the following line was no longer wrapped in a condtional, if query_hash[:query][:bool]
        # When I commented out the line, nothing broke.. not sure if it is relevant.
        # query_hash[:query].except!( :terms)

        if options[:command] == 'stats'
          query_hash.merge! add_aggregations(params, options, config)
        end

        query_hash = set_query_source(query_hash, nested_query, nested_fields, query_fields, all_programs_nested)

        if options[:sort] && !options[:sort].empty?
          set_sort_filter_in_query_hash(options[:sort], config, query_hash)
        end

        query_hash
      end

      private

      def generate_squery(params, options, config)
        squery = Stretchy.query(type: 'document')
        squery = search_location(squery, options)
        search_fields_and_ranges(squery, params, config)
      end

      # Wrapper for Stretchy aggregation clause builder (which wraps ElasticSearch (ES) :aggs parameter)
      # Extracts all extended_stats aggregations from ES, to be filtered later
      # Is a no-op if no fields are specified, or none of them are numeric
      def add_aggregations(params, options, config)
        agg_hash = options[:fields].inject({}) do |memo, f|
          if config.column_field_types[f.to_s] && ["integer", "float"].include?(config.column_field_types[f.to_s])
            memo[f.to_s] = { extended_stats: { "field" => f.to_s } }
          end
          memo
        end

        agg_hash.empty? ? {} : { aggs: agg_hash }
      end

      def nested_data_types()
        DataMagic.config.es_data_types["nested"]
      end

      def field_type_nested?(field_name)
        if nested_data_types()
          nested_data_types().any? {|nested| field_name.start_with? nested }
        end
      end

      def nested_fields(submitted_fields)
        nested_fields = []
        if !submitted_fields.empty?
          submitted_fields.each do |field_name|
            if field_type_nested?(field_name)
              nested_fields.push(field_name)
            end
          end
        end
        nested_fields
      end

      def determine_query_term_datatypes(params)
        nested_terms = params.keys.select { |key| field_type_nested?(key) }
        nested_query_pairs = {}

        nested_terms.each do |key|
          split_key_terms = key.split(".")
          nested, *standard_fields = split_key_terms

          dotted_field = standard_fields.join(".")
          if dotted_field.include?("__range") || dotted_field.include?("__not")
            dotted_field = dotted_field.chomp("__range")
            dotted_field = dotted_field.chomp("__not")
          end

          field_type = @@dictionary[dotted_field]["type"].nil? ? "string" : @@dictionary[dotted_field]["type"]
          value = params[key]
  
          if (field_type == "string" || field_type == "integer") && value.is_a?(String) && /,/.match(value) # lists of integers or strings
            value = value.split(',').map do |str|
              if field_type == "integer"
                formatted_string = str.tr("[]","").to_i
              else
                formatted_string = str.tr("[]","")
              end
              formatted_string
            end
          end
          nested_query_pairs[key] = value
        end

        if !nested_terms.empty?
          nested_terms.each do |key|
            params.except!( key )
          end
        end

        query_pairs = params

        {
          nested_query_pairs: nested_query_pairs,
          query_pairs:        query_pairs
        }
      end

      def get_restrict_fields(options)
        options[:fields].map(&:to_s)
      end

      # Evaluate and collect sort param properties
      # Returns a hash
      def organize_sort_params(sort_param, config)
        sort_param.to_s.scan(/(\w+[\.\w]*):?(\w*)/).map do |field_name, direction|
          direction = 'asc' if direction.empty?

          if config.field_type(field_name) == 'autocomplete'
            field_name = "_#{field_name}"
          end

          nested_field_type = field_type_nested?(field_name)

          {
            :direction          => direction,
            :is_nested_datatype => nested_field_type,
            :field_name         => field_name
          }
        end

      end

      def define_nested_sort(sort_property_set, query_hash)
        h = sort_property_set
        path = nested_data_types().select { |n| h[:field_name].start_with? n }.first

        filter = !query_hash.dig(:query,:bool,:filter,:nested,:query).nil? ? query_hash[:query][:bool][:filter][:nested][:query] : nil

        {
          h[:field_name] => {
            :order => h[:direction],
            :nested_path => path,
            :nested_filter => filter
          }
        }
      end

      def set_sort_filter_in_query_hash(sort_param, config, query_hash)
        sort_key_properties = organize_sort_params(sort_param, config)

        query_hash[:sort] = sort_key_properties.map do |h|
          if h[:is_nested_datatype] == true
            define_nested_sort(h, query_hash)
          else
            { h[:field_name] => { order: h[:direction] }}
          end
        end

        query_hash
      end

      def to_number(value)
        value =~ /\./ ? value.to_f : value.to_i
      end

      def search_fields_and_ranges(squery, params, config)
        params.each do |param, value|
          field_type = config.field_type(param)
          if field_type == "name"
            squery = include_name_query(squery, param, value)
          elsif field_type == "autocomplete"
            squery = autocomplete_query(squery, param, value)
          elsif match = /(.+)__(range|ne|not)\z/.match(param)
            field, operator = match.captures.map(&:to_sym)
            squery = range_query(squery, operator, field, value)
          elsif (field_type == "string" || field_type == "integer") && value.is_a?(String) && /,/.match(value) # lists of integers or strings
            squery = list_query(squery, param, value, field_type)
          else # field equality
            squery = squery.filter.match(param => value)
          end
        end
        squery
      end

      def include_name_query(squery, field, value)
        value = value.split(' ').map { |word| "#{word}*"}.join(' ')
        squery.match.query(
          # we store lowercase name in field with prefix _
          "wildcard": { "_#{field}" => { "value": value.downcase } }
        )
      end

      def range_query(squery, operator, field, value)
        if operator == :ne or operator == :not      # field negation
          squery.where.not(field => value)
        else                                        # field range
          squery.filter(
            or: build_ranges(field, value.split(','))
          )
        end
      end

      def autocomplete_query(squery, field, value)
        squery.match.query(
          common: {
            field => {
              query: value,
              cutoff_frequency: 0.001,
              low_freq_operator: "and"
            }
          })
      end

      def list_query(squery, field, value, field_type)
        if ( field_type == "string")
          filter = value.split(',').map(&:to_str)
        else
          filter = value.split(',').map(&:to_i)
        end

        squery.filter(
          terms: {
            field => filter }
        )
      end

      def build_ranges(field, range_strings)
        range_strings.map do |range|
          min, max = range.split('..')
          values = {}
          values[:gte] = to_number(min) unless min.empty?
          values[:lte] = to_number(max) if max
          {
            range: { field => values }
          }
        end
      end

      # Handles location (currently only uses SFO location)
      def search_location(squery, options)
        distance = options[:distance]
        location = Zipcode.latlon(options[:zip])

        if distance && !distance.empty?
          # default to miles if no distance given
          unit = distance[-2..-1]
          distance = "#{distance}mi" if unit != "km" and unit != "mi"
          squery = squery.geo_distance(field: 'coords', distance: distance, location: {lat: location[:lat], lon: location[:lon]})
        end
        squery
      end

      def set_query_source(query_hash, nested_query, nested_fields, query_fields, all_programs_nested)
        # The distinction between nested datatype query vs non-nested datatype query refers 
        # to the datatype of the field that must be matched.

        # The distinction between nested_fields vs query_fields refers to the fields returned in the response. The
        # response fields come from different sources depending on the query.
        
        # if there is a nested_query && the all_programs_nested is not true
        # OR if there are non-nested query_fields AND no nested fields
        if nested_query && !all_programs_nested || (!query_fields.empty? && nested_fields.empty?)
          query_hash[:_source] = false
        
        # if this is NOT a nested_query AND there are nested fields, then filter source on those fields
        # OR if the query includes a nested query AND the all_programs_nested option is passed
        elsif !nested_query && !nested_fields.empty? || (nested_query && all_programs_nested)
          query_hash[:_source] = nested_fields

        # if neither fields, nor a source filter, then exclude fields from source beginning with underscores
        else
          query_hash[:_source] = { exclude: ["_*"] }
        end

        # if this is a nested_query AND there are nested fields, then those fields should be passed to 
        # post_es_response key, rather than :_source
        if nested_query && !nested_fields.empty?
          query_hash[:post_es_response][:nested_fields_filter] = nested_fields
        end

        query_hash
      end
    end
  end
end
