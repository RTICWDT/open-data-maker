require 'typhoeus'
require 'typhoeus/adapters/faraday'
require 'elasticsearch'
require 'safe_yaml'
require 'csv'
require 'stretchy'
require 'hashie'
require './lib/nested_hash'
require 'aws-sdk'
require 'uri'
require 'cf-app-utils'
require 'logger'
require 'set'

require_relative 'data_magic/config'
require_relative 'data_magic/index'
require_relative 'data_magic/query_builder'
require_relative 'data_magic/error_checker'
require_relative 'zipcode/zipcode'

SafeYAML::OPTIONS[:default_mode] = :safe

class IndifferentHash < Hash
  include Hashie::Extensions::MergeInitializer
  include Hashie::Extensions::IndifferentAccess
end

module DataMagic
  class << self
    attr_accessor :config
    def logger
      Config.logger
    end
  end

  DEFAULT_PAGE_SIZE = 20
  MAX_PAGE_SIZE = 100
  DEFAULT_EXTENSIONS = ['.csv']
  DEFAULT_PATH = './sample-data'
  class InvalidData < StandardError
  end
  class InvalidDictionary < StandardError
  end

  def self.s3
    if @s3.nil?
      s3cred = {}
      if ENV['VCAP_APPLICATION']
        s3cred = ::CF::App::Credentials.find_by_service_name(ENV['s3_bucket_service'] || 'bservice')
      else
        s3cred = {'access_key'=>  ENV['s3_access_key'], 'secret_key' => ENV['s3_secret_key'], 'region' => ENV['s3_region']}
      end
      # logger.info "s3cred = #{s3cred.inspect}"
      if ENV['RACK_ENV'] != 'test'
        s3_access_key = s3cred['access_key'] || s3cred['access_key_id']
        s3_secret_key = s3cred['secret_key'] || s3cred['secret_access_key']
        ::Aws.config[:credentials] = ::Aws::Credentials.new(s3_access_key, s3_secret_key)
      end
      ::Aws.config[:region] = s3cred['region'] || 'us-east-1'
      @s3 = ::Aws::S3::Client.new
      # logger.info "@s3 = #{@s3.inspect}"
    end
    @s3
  #  logger.info "response: #{response.inspect}"
  end

  #========================================================================
  #   Public Class Methods
  #========================================================================

  # thin layer on elasticsearch query
  def self.search(terms, options = {})
    terms = IndifferentHash.new(terms)
    errors = ErrorChecker.check(terms, options, config)
    return { errors: errors } if errors.length > 0

    query_body = QueryBuilder.from_params(terms, options, config)
    result_processing_info = query_body[:post_es_response]
    query_body.delete(:post_es_response)

    index_name = index_name_from_options(options)
    logger.info "search terms:#{terms.inspect}"

    full_query = {
      index: index_name,
      type: 'document',
      body: query_body
    }

    # Per https://www.elastic.co/guide/en/elasticsearch/reference/current/search-request-body.html:
    # "the search_type and the query_cache must be passed as query-string parameters"
    if options[:command] == 'stats'
      full_query.merge! :search_type => 'count'
    end

    logger.info "FULL_QUERY: #{full_query.inspect}"

    time_start = Time.now.to_f
    result = client.search full_query
    
    search_time = Time.now.to_f - time_start
    logger.info "ES query time (ms): #{result["took"]} ; Query fetch time (s): #{search_time} ; result: #{result.inspect[0..500]}"

    # Everything after this is aimed at processing the results from ES for the browser 
    hits = result["hits"]
    total = hits["total"]

    results = process_result_from_es( hits, result_processing_info, query_body, options )
    
    metadata = {
      "total" => total,
      "page" => query_body[:from] / query_body[:size],
      "per_page" => query_body[:size]
    }
    if options[:debug]
      metadata["search_time"] = search_time
      metadata["ES_took_ms"] = result["took"]
    end

    # assemble a simpler json document to return
    simple_result =
    {
      "metadata" => metadata,
      "results" => 	results
    }

    if options[:command] == 'stats'
      # Remove metrics that weren't requested.
      aggregations = result['aggregations'] || {}
      aggregations.each do |f_name, values|
        if options[:metrics] && options[:metrics].size > 0
          aggregations[f_name] = values.reject { |k, v| !(options[:metrics].include? k) }
        else
          # Keep everything is no metric list is provided
          aggregations[f_name] = values
        end
      end

      simple_result.merge!({"aggregations" => aggregations})
    end
  
    simple_result
  end

  private

  def self.process_result_from_es( hits, result_processing_info, query_body, options )
    results = []
    # Collect list of nested fields that need to be filtered
    # This is neccessary because the standard ES fields filter creates arrays from nested data, which we don't want
    nested_fields_filter = result_processing_info[:nested_fields_filter] ? result_processing_info[:nested_fields_filter] : []
    all_programs_nested = options[:all_programs_nested]
    
    if query_body.dig(:_source) == { exclude: ["_*"] }
      # we're getting the whole document and we can find in _source
      results = hits["hits"].map {|hit| hit["_source"]}

      # Tested - implementation of nested vs dotted option - when line below is exposed, 
      # and &keys_nested=true is in query, I get Error: JSON::NestingError - nesting of 100 is too deep
      # results = options[:keys_nested] ? NestedHash.new(results) : results
    else
      results = hits["hits"].map do |hit|
        found = hit.fetch("fields", {})
        
        # Unless a query term is also a nested data type, fields requested for a nested_data_type are defined under _source
        from_source = hit.fetch("_source", {})
        dotted_from_source = NestedHash.new.withdotkeys(from_source)
        found = found.merge(dotted_from_source)
        
        delete_set = Set[]
        delete_set.each { |k| found.delete k }

        found = transform_array_values(found)

        # re-insert null fields that didn't get returned by ES
        if query_body[:fields]
          query_body[:fields].each do |field|
            if !(found.has_key?(field) || found.has_key?(field.to_s)) && !delete_set.include?(field || field.to_s)
              found[field] = nil
            end
          end
        end

        # When an inner query is submitted, the nested data_type fields are under inner_hits
        inner = hit.fetch("inner_hits", {})

        if !all_programs_nested && !inner.empty?
          found = collect_inner_hits(inner, found, nested_fields_filter)
        end

        # If keys_nested option passed in params, then return result keys in nested format
        # Default setting is to return results with dotted keys
        found = options[:keys_nested] ? NestedHash.new(found) : found

        found
      end
    end

    results
  end

  def self.field_type_nested?(field_name)
    nested_datatypes = DataMagic.config.es_data_types["nested"]

    if nested_datatypes
      nested_datatypes.any? {|nested| field_name.start_with? nested }
    end
  end

  def self.transform_array_values(found)
    # each result looks like this:
    # {
    #   "city"=>["Springfield"], 
    #   "address"=>["742 Evergreen Terrace"], 
    #   "children" => [{...}, {...}, {...}] 
    # }
    found.keys.each do |key|
      nested_data_type = field_type_nested?(key)
      
      # Keep nested datatypes in an array, even when there is just one program
      if !nested_data_type && found[key].length <= 1
        found[key] = found[key][0]
      else
        found[key] = found[key]
      end
    end
    # Now, it looks like the following....
    # {
    #   "city"=>"Springfield", 
    #   "address"=>"742 Evergreen Terrace", 
    #   "children" => [{...}, {...}, {...}] 
    # }

    found
  end

  def self.collect_inner_hits(inner, found, nested_fields_filter)
    nested_details_hash = {}

    inner.keys.each do |inn_key|
      inner_details = inner[inn_key]["hits"]["hits"].map do |nested_obj|
        details = nested_obj.fetch("_source", {})
        n_hash = NestedHash.new
        
        details.keys.each do |key|
          n_hash[key] = details[key]
        end
        # Convert to dotted keys
        n_hash = n_hash.withdotkeys

        # If there is a fields filter for nested datatypes, apply it here
        if !nested_fields_filter.empty?
          keys_to_keep = nested_fields_filter.select { |f| f.start_with? inn_key }.map do |n|
            n.gsub(inn_key + ".","")
          end
          n_hash_filtered = n_hash.select { |k| keys_to_keep.include?(k) }
        end

        !n_hash_filtered.nil? ? n_hash_filtered : n_hash
      end

      # Set the nested data type string as the key and the array of inner hits as the value
      nested_details_hash[inn_key] = inner_details
    end

    # If nested hits, combine with other fields in found hash
    if !nested_details_hash.empty?
      found = found.merge(nested_details_hash)
    end

    found
  end

  def self.document_data_type(hash, root='')
    hash.each do |key, value|
      if value.is_a?(Hash) && value[:type].nil?  # things are nested under this
        dotted_path = root + key
        data_type = get_data_type(dotted_path)
        hash[key] = {
          type: data_type,
          properties: value
        }
        # need to include nested data-type values in parent document
        hash[key][:include_in_parent] = true if data_type === 'nested'
        document_data_type(value, dotted_path + '.')
      end
    end
  end

  def self.get_data_type(dotted_path)
      default_type = 'object'
      self.config.es_data_types.each do |key, types|
        if types.include?(dotted_path)
          default_type = key
          break
        end
      end
      default_type
  end

  def self.create_index(es_index_name = nil, field_types={})
    # logger.info "create_index field_types: #{field_types.inspect[0..500]}"
    es_index_name ||= self.config.scoped_index_name
    field_types['location'] = 'lat_lon' # custom lat_lon type maps to geo_point with additional field options
    es_types = NestedHash.new.add(es_field_types(field_types))
    document_data_type(es_types)
    begin
      logger.info "====> creating index with type mapping"
      client.indices.create base_index_hash(es_index_name, es_types)
    rescue Elasticsearch::Transport::Transport::Errors::BadRequest => error
      if error.message.include? "IndexAlreadyExistsException"
        logger.debug "create_index failed: #{es_index_name} already exists"
      else
        logger.error error.to_s
        raise error
      end
    end
    es_index_name
  end

  def self.base_index_hash(es_index_name, es_types)
    shard_number = (RACK_ENV == 'test') ? 1 : 3
    replica_number = (RACK_ENV == 'test') ? 0 : 2
    {
        index: es_index_name,
        body: {
            settings: {
                number_of_shards: shard_number,
                number_of_replicas: replica_number,
                analysis: {
                    filter: {
                        autocomplete_filter: {
                            type: 'edge_ngram',
                            min_gram: 1,
                            max_gram: 25,
                        },
                        autocomplete_word_delimiter: {
                            type: 'word_delimiter',
                            preserve_original: true,
                            split_on_case_change:false,
                            split_on_numerics: false,
                            stem_english_possessive:false
                        }
                    },
                    analyzer: {
                        autocomplete_index: {
                            tokenizer: 'whitespace',
                            filter: ['lowercase', 'autocomplete_word_delimiter', 'autocomplete_filter'],
                            type: 'custom'
                        },
                        autocomplete_search: {
                            tokenizer: 'whitespace',
                            filter: ['lowercase','autocomplete_word_delimiter'],
                            type: 'custom'
                        }
                    }
                }
            },
            mappings: {
                document: { # type 'document' is always used for external indexed docs
                   properties: es_types
                }
            }
        }
    }
  end

  # convert the types from data.yaml to Elasticsearch-specific types
  def self.es_field_types(field_types)
    custom_type = {
      'literal' => {type: 'string', index:'not_analyzed'},
      'name' => {type: 'string', index:'not_analyzed'},
      'lowercase_name' => {type: 'string', index:'not_analyzed', store: false},
      'autocomplete' => {type: 'string', analyzer: 'autocomplete_index', search_analyzer: 'autocomplete_search'},
      'lat_lon' => { type: 'geo_point', lat_lon: true, store: true }
   }
    field_types.each_with_object({}) do |(key, type), result|
      result[key] = custom_type[type]
      result[key] ||= { type: type }
    end
  end


  # get the real index name when given either
  # endpoint: api endpoint configured in data.yaml
  # index: index name
  def self.index_name_from_options(options)
    api = options[:endpoint]
    options[:index] = options['index'].to_sym if options['index']
    logger.info "WARNING: DataMagic.search options api will override index, only one expected"  if api and options[:index]
    if api
      index_name = config.find_index_for(api)
      if index_name.nil?
        raise ArgumentError, "no configuration found for '#{api}', available endpoints: #{self.config.api_endpoint_names.inspect}"
      end
    else
      index_name = options[:index]
    end
    index_name = self.config.scoped_index_name(index_name)
  end

  def self.index_data_if_needed
    logger.info "index_data_if_needed"
    if @index_thread and @index_thread.alive?
      logger.info "already indexing... skip!"
    else
      if config.update_indexed_config
        logger.info "new config detected... hitting the big RESET button"
        @index_thread = Thread.new do
          logger.info "re-indexing..."

          self.import_with_dictionary
        end
      end
    end
  end

  def self.reindex
    logger.info "reindex"
    if @index_thread and @index_thread.alive?
      logger.info "kill off old indexing process"
      Thread.kill(@index_thread)
      @index_thread = nil
    end

    logger.info "DELETE the index and RELOAD config..."
    config.delete_index_and_reload_config  # refresh the config
    @index_thread = Thread.new do
      logger.info "re-indexing!"
      self.index_with_dictionary
    end
  end


  def self.eservice_uri
    if @eservice_uri.nil?
      eservice = ::CF::App::Credentials.find_by_service_name(ENV['es_service'] || 'eservice')
      logger.info "eservice: #{eservice.inspect}"
      fail "Please set up eservice credentials in Cloud Foundry env" if eservice.nil?
      @eservice_uri = eservice['url'] || eservice['uri']
    end
    @eservice_uri
  end

  def self.client
    timeout = (ENV['INDEX_APP'] == 'enable') ? 10*60 : 5*60
    opts =
    {
      transport_options: {
        request: {
          timeout: timeout,
          open_timeout: timeout
        }
      }
    }
    if ENV['ES_DEBUG']
      tracer = Logger.new(STDOUT)
      tracer.formatter = ->(_s, _d, _p, m) { "#{m.gsub(/^.*$/) { |n| '   ' + n }}\n" }
      opts[:tracer] = tracer
    end
    if @client.nil?
      if ENV['VCAP_APPLICATION']    # Cloud Foundry
        logger.info "connect to Cloud Foundry elasticsearch service"
        logger.info "eservice_uri: #{eservice_uri}"
        opts[:host] = eservice_uri
      end
      if ENV['ES_URI']
        opts[:host] = ENV['ES_URI'] # env override for eservice uri
      end
      logger.info "default local elasticsearch connection"
      @client = ::Elasticsearch::Client.new(opts)
      @client = Elasticsearch::Client.new(opts)
      Stretchy.client = @client   # use a custom client
    end
    @client
  end

  # call this before calling anything that requires data.yaml
  # this will load data.yaml, and optionally index referenced data
  # options hash
  #   load_now: default load in background,
  #             false don't load,
  #             true load immediately, wait for complete indexing
  def self.init(options = {})
    logger.info "--"*20
    logger.info "    DataMagic init VCAP_APPLICATION=#{ENV['VCAP_APPLICATION'].inspect}"
    logger.info "--"*20
    # logger.info "options: #{options.inspect}"
    # logger.info "self.config: #{self.config.inspect}"
    if self.config.nil?   # only init once
      #::Aws.eager_autoload!       # see https://github.com/aws/aws-sdk-ruby/issues/833
      self.config = Config.new(s3: self.s3)    # loads data.yaml
      self.client   # make sure we can set up the Elasticsearch client
      self.index_data_if_needed unless options[:load_now] == false
      @index_thread.join if options[:load_now] and @index_thread
    end
  end # init

  # DANGER!
  # removes all indices associated with the loaded data.yaml
  def self.destroy
    logger.info "DataMagic.destroy"
    @index_thread.join unless @index_thread.nil?   # finish up indexing, if needed
    self.config.clear_all unless config.nil?
    self.config = nil
  end
end
