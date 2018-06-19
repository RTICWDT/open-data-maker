require 'data_magic'

desc 'delta update current ES index with delta data file. ARG 1 must be title as specified in data.yaml, e.g., Most-Recent-Cohorts-All-Data-Elements.csv. ARG 2 is the filename of the new delta file. USAGE delta[orignal.csv,delta.csv]'
task :delta, [:original, :update] => :environment do |t, args|
  options = {}
  options[:delta_original] = args[:original] || 'Most-Recent-Cohorts-All-Data-Elements.csv'
  options[:delta_update] = args[:update]
  DataMagic.import_with_delta(options)
end
