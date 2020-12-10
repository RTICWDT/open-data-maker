require 'json'

module DataMagic
	module QueryBuilder
		module NestedQueryBuilder
			class << self

				def integrate_query_pairs(nested_query_pairs, query_hash, query_pairs)
					if query_pairs.empty?
						build_query_from_nested_datatypes(nested_query_pairs, query_hash)
					else
						build_query_from_nested_and_nonnested_datatypes(nested_query_pairs, query_hash)
					end
				end

				def build_query_from_nested_datatypes(nested_query_pairs, query_hash)
					add_bool_to_query_hash(query_hash)
					add_filter_key_to_bool_on_query_hash(query_hash)
					query_hash[:query][:bool][:filter] = build_nested_query(nested_query_pairs)
	
					query_hash
				end

				def build_query_from_nested_and_nonnested_datatypes(nested_query_pairs, query_hash)
					if !query_hash.dig(:query,:bool).nil?
						bool_keys_minus_filter = query_hash[:query][:bool].keys.select {|key| key != :filter } 

						if !query_hash.dig(:query,:bool,:filter).nil?
							query_hash_with_nested_query = incorporate_nested_with_existing_filter(query_hash, nested_query_pairs)
					
							bool_keys_minus_filter.each do |key|
								query_hash_with_nested_query = move_key_values_to_filter(key, query_hash_with_nested_query)
							end
						end
					elsif !query_hash.dig(:query,:common).nil?
						query_hash_with_nested_query = incorporate_nested_with_autocomplete_query(query_hash, nested_query_pairs)
					elsif !query_hash.dig(:query,:or).nil?
						query_hash_with_nested_query = incorporate_nested_with_range_query(query_hash, nested_query_pairs)
					else
						query_hash_with_nested_query = incorporate_nested_with_nonfilter_query(query_hash, nested_query_pairs)
					end

					query_hash_with_nested_query
				end

				# in this function, the query_pairs are of the form:
				#     { field_label => value }
				#     {"latest.programs.cip_4_digit.credential.level__not"=>"3"}
				def build_nested_query(nested_query_pairs)
					paths_and_terms = organize_info_for_nested_query(nested_query_pairs)

					paths = Set[]
					paths_and_terms.each { |hash| paths.add(hash[:path]) }

					term_keys = Set[]
					paths_and_terms.each { |hash| term_keys.add(hash[:term].keys.first) }

					if paths.length == 1
						path        = paths.to_a[0]
						terms       = paths_and_terms.map { |item| item[:term] }
						terms_hash 	= { terms: [] }

						paths_and_terms.each do |item|
							key = item[:term].keys[0]
							value = item[:term][key]

							if key == :terms
								terms_hash[:terms].push(item[:term])
							elsif terms_hash.dig(key).nil?
								terms_hash[key] = [value]
							else
								terms_hash[key].push(value)
							end
						end

						if terms_hash[:terms].empty?
							terms_hash.delete(:terms)
						end

						base = get_nested_query_base(path)

						base[:nested][:query] = { bool: { filter: [] }}

						term_keys.each do |key|
							if key.to_s.include?("must")
								base[:nested][:query][:bool][:filter].push({ bool: { key => terms_hash[key] }})
							elsif key == :terms
								terms_hash[key].each {|item| base[:nested][:query][:bool][:filter].push(item) }
							elsif key == :or
								terms_hash[key].each {|item| base[:nested][:query][:bool][:filter].push({:or => [item]})}
							else
								base[:nested][:query][:bool][:filter].push({key => terms_hash[key]})
							end
						end

						base
					end
				end

        def organize_info_for_nested_query(nested_query_pairs)
					paths_and_terms = organize_paths_and_terms_for_query_info(nested_query_pairs)

					paths_and_terms_cleaned_up = paths_and_terms.map do |p_and_t|
						{
							path: p_and_t[:path],
							term: p_and_t[:term]
						}
					end
	
					paths_and_terms_cleaned_up
				end

				def organize_paths_and_terms_for_query_info(nested_query_pairs)
					paths_and_terms = []
					nested_query_pairs.each do |key, value|
						if nested_data_types.any? {|nested| key.start_with? nested }
							path = nested_data_types.select {|nested| key.start_with? nested }.join("")
						end
						
						range_query = key.include?("__range")
						not_query 	= key.include?("__not")
						or_query 		= value.is_a? Array

						if range_query
							query_term = get_nested_range_query(key, value)
						elsif or_query && !not_query
							query_term = { terms: { key => value }}
						else
							query_term = get_nested_must_match_terms(key, value)
						end

						paths_and_terms.push({
							path: path,
							term: query_term
						})
					end

					paths_and_terms
				end

				def nested_data_types()
					DataMagic.config.es_data_types["nested"]
				end

				def outer_range_wrapper(key, range_values)
					field = key.chomp("__range")
					range_hash = { 
						or: {
							range: {
								field => range_values
							}
						}
					}
	
					range_hash
				end
				
				def get_nested_range_query(key, value)
					range_params = value.split("..")
					first, last = range_params
					last = last.nil? ? [] : last
					first = first.nil? ? [] : first
	
					if !first.empty? && !last.empty?
						range_values = { gte: first, lte: last } 
					elsif first.empty?
						range_values = { lte: last }
					else
						range_values = { gte: first }
					end
	
					range_hash = outer_range_wrapper(key, range_values)

					range_hash
				end

				def get_nested_must_match_terms(key, value)
					if key.include?("__not")
						field = key.chomp("__not")
						must_key = :must_not
					else
						field = key
						must_key = :must
					end

					if value.is_a? Array
						term_key = :terms
					else
						term_key = :match
					end

					{ must_key => { term_key => { field => value }}}
				end
	
				def add_must_key_to_bool_on_query_hash(query_hash)
					query_hash[:query][:bool][:must] = {}
	
					query_hash
				end

        def add_bool_to_query_hash(query_hash)
					query_hash[:query][:bool] = {}
				end
        
				def add_filter_key_to_bool_on_query_hash(query_hash)
					query_hash[:query][:bool][:filter] = {}
	
					query_hash
				end


				def get_nested_query_base(path)
					{ 
						nested: {
							path: path,
							inner_hits: {
									size: DataMagic::MAX_NESTED_RESULT
							}
						}
					}
				end

				# Combining nested and non-nested
				def incorporate_nested_with_nonfilter_query(query_hash, nested_query_pairs)
					nested_query = build_nested_query(nested_query_pairs)
	
					query_hash[:query][:bool] = { must: {} }
					query_hash[:query][:bool][:filter] = nested_query
	
					if !query_hash.dig(:query,:match).nil?
						match_terms = query_hash[:query][:match]
						query_hash[:query][:bool][:must][:match] = match_terms
						query_hash[:query].delete(:match)
					elsif !query_hash.dig(:query,:terms).nil?
						terms = query_hash[:query][:terms]
						query_hash[:query][:bool][:must][:terms] = terms
						query_hash[:query].delete(:terms)
					end
					
					query_hash[:query][:bool][:filter] = nested_query
	
					query_hash
				end
	
				def incorporate_nested_with_existing_filter(query_hash, nested_query_pairs)
					nested_query = build_nested_query(nested_query_pairs)
					
					query_hash[:query][:bool][:filter].push(nested_query)
	
					query_hash
				end
	
	
				# Called from condition within incorporate_nested_with_autocomplete_query
				def move_common_key_to_must_key_on_query_hash(query_hash)
					common = {}
					common[:common] = query_hash[:query][:common]
					
					query_hash[:query].delete(:common)
					query_hash[:query][:bool][:must] = common
					
					query_hash
				end
	
				def incorporate_nested_with_autocomplete_query(query_hash, nested_query_pairs)
					if (query_hash.dig(:query,:bool).nil?)
						add_bool_to_query_hash(query_hash)
					end

					if (query_hash.dig(:query,:bool,:must).nil?)
						add_must_key_to_bool_on_query_hash(query_hash)
						move_common_key_to_must_key_on_query_hash(query_hash)
					else
						add_filter_key_to_bool_on_query_hash(query_hash)
					end
	
					query_hash[:query][:bool][:filter] = build_nested_query(nested_query_pairs)
	
					query_hash
				end
	
				def move_or_key_to_filter_array_on_query_hash(query_hash)
					or_key = query_hash[:query][:or]
	
					query_hash[:query].delete(:or)
					query_hash[:query][:bool][:filter].push({ or: or_key })
					
					query_hash
				end
	
				def incorporate_nested_with_range_query(query_hash, nested_query_pairs)
					if (query_hash.dig(:query,:bool).nil?)
						add_bool_to_query_hash(query_hash)
					end
					
					if (query_hash.dig(:query,:bool,:filter).nil?)
						query_hash[:query][:bool][:filter] = []
						move_or_key_to_filter_array_on_query_hash(query_hash)
	
						# TODO - what if filter key exists but has another hash, rather than an array???
					end
	
					query_hash[:query][:bool][:filter].push(build_nested_query(nested_query_pairs))
	
					query_hash
				end
	
				def move_key_values_to_filter(key, query_hash)
					to_move = query_hash[:query][:bool][key]
	
					if (key == :must || key == :must_not)
						query_hash[:query][:bool][:filter].push({
							bool: {
								key => to_move[0]
							}
						})
					end
	
					query_hash[:query][:bool].delete(key)
	
					query_hash
				end
		
				def add_must_key_to_bool_on_query_hash(query_hash)
					query_hash[:query][:bool][:must] = {}

					query_hash
				end
			end
		end
	end
end