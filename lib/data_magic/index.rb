require 'forwardable'

require_relative 'config'
require_relative 'index/builder_data'
require_relative 'index/event_logger'
require_relative 'index/document'
require_relative 'index/document_builder'
require_relative 'index/importer'
require_relative 'index/output'
require_relative 'index/repository'
require_relative 'index/row_importer'
require_relative 'index/super_client'

require 'action_view'  # for distance_of_time_in_words (logging time)
include ActionView::Helpers::DateHelper  # for distance_of_time_in_words (logging time)

module DataMagic
  # data could be a String or an io stream
  def self.import_csv(data, options={})
    Index::Importer.process(data, options)
  end

  def self.log_index_start
    start_time = Time.now
    Config.logger.debug "--- Indexing Begins, starting at #{start_time}"
    start_time
  end

  def self.log_index_end(start_time)
    end_time = Time.now
    logger.debug "indexing complete: #{distance_of_time_in_words(end_time, start_time)}"
    logger.debug "duration: #{end_time - start_time}"
  end

  def self.index_file_process(options = {}, filepath)
    begin
      logger.debug "--"*40
      logger.debug "--    #{filepath}"
      logger.debug "--"*40
      file_start = Time.now
      data = config.read_path(filepath)
      rows, _ = DataMagic.import_csv(data, options)
      file_end = Time.now
      logger.debug "imported #{rows} rows in #{distance_of_time_in_words(file_end, file_start)}, ms: #{file_end - file_start}"
    rescue DataMagic::InvalidData => e
      Config.logger.debug "Error: skipping #{filepath}, #{e.message}"
    end
  end

  # pre-condition: index is already created w/ config
  def self.index_with_dictionary(options = {})
    start_time = log_index_start
    # optionally continue importing from a named file (see import.rake)
    starting_from = 0
    if options[:continue]
      starting_from = config.files.find_index { |file| file.match( /#{options[:continue]}/ ) }
      logger.info "Indexing continues with file: #{options[:continue]}" unless starting_from.nil?
    end
    logger.info "files: #{self.config.files[starting_from.to_i..-1]}"
    config.files[starting_from.to_i..-1].each_with_index do |filepath, index|
      fname = filepath.split('/').last
      logger.debug "indexing #{fname} #{starting_from + index} file config:#{config.additional_data_for_file(starting_from + index).inspect}"
      options[:add_data] = config.additional_data_for_file(starting_from + index)
      options[:root] = config.info_for_file(starting_from + index, :root)
      options[:only] = config.info_for_file(starting_from + index, :only)
      options[:nest] = config.info_for_file(starting_from + index, :nest)
      index_file_process(options, filepath)
    end
    log_index_end(start_time)
  end

  def self.import_with_dictionary(options = {})
    options[:mapping] = config.field_mapping
    options = options.merge(config.options)
    es_index_name = self.config.load_datayaml(options[:data_path])
    unless config.index_exists?(es_index_name)
      logger.info "creating #{es_index_name}"   # TO DO: fix #14
      create_index es_index_name, config.field_types
    end

    index_with_dictionary(options)

  end # import_with_dictionary

  def self.index_with_delta(options = {})
    # delta updates the current index with a single file
    if options[:delta_original]
      start_time = log_index_start
      # find the index of the delta file from the config by the :delta_only key (see delta.rake)
      original_file_index = nil
      config.files.each_with_index do|file, index|
        if config.info_for_file(index, :delta_only)
          original_file_index = index
        end
      end

      unless original_file_index
        raise ArgumentError, "delta_original file must contiain :delta_only key in data.yaml. No :delta_only key found."
      end

      # use specified :delta_update filename, or fall back to :delta_original if not provided
      delta_filename = options[:delta_update] || options[:delta_original]
      config.files[original_file_index..original_file_index].each do |filepath|
        original_fname = filepath.split('/').last
        # update filepath to use a "delta" subdirectory within DATA_PATH (e.g, <DATA_PATH>/delta/<CSV_FILE> )
        delta_filepath = filepath.gsub(/#{original_fname}/, "delta/#{delta_filename}" )
        logger.debug "delta update with #{delta_filename} file config:#{config.additional_data_for_file(original_file_index).inspect}"
        options[:add_data] = config.additional_data_for_file(original_file_index)
        # Append the :delta_only array as our :only fields
        options[:only] = config.info_for_file(original_file_index, :delta_only)
        options[:nest] = config.info_for_file(original_file_index, :nest)
        options[:root] = false # we are not creating new documents
        options[:nest][:parent_missing] = 'skip' # we allow skips
        index_file_process(options, delta_filepath)
      end
      log_index_end(start_time)
    else
      raise ArgumentError, "delta.rake requires 'delta_original' argument to be a filename from the config. No option[:delta_original] provided."
    end
  end

  # pre-condition: index is already created w/ config
  def self.import_with_delta(options = {})
    options[:mapping] = config.field_mapping
    options = options.merge(config.options)
    es_index_name = self.config.load_datayaml(options[:data_path])
    index_with_delta(options)
  end # import_with_delta

private
  def self.valid_types
    %w[integer float string literal name autocomplete boolean]
  end

end # module DataMagic
