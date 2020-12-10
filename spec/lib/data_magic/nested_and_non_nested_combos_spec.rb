require 'spec_helper'
require 'data_magic'
require 'hashie'

describe DataMagic::QueryBuilder do

  before :example do
    DataMagic.destroy
    DataMagic.client
    ENV['DATA_PATH'] = './spec/fixtures/nested_data_type'
    DataMagic.config = DataMagic::Config.new
  end

  after :example do
    DataMagic.destroy
  end

  RSpec.configure do |c|
    c.alias_it_should_behave_like_to :it_correctly, 'correctly:'
  end

  let(:nested_meta) { { post_es_response: {}, from: 0, size: 20, _source: false } }
  let(:options) { {} }
  let(:query_hash) { DataMagic::QueryBuilder.from_params(subject, options, DataMagic.config) }
  let(:non_nested_range) {{
    or: [{
      range: {
        "school.degrees_awarded.predominant": {
          "gte": 1,
          "lte": 3
        }
      }
    }]
  }}
  let(:non_nested_autocomplete) {{
    common: {
      "school.name" => {
        query: "arizona",
        cutoff_frequency: 0.001,
        low_freq_operator: "and"
      }
    }
  }}
  let(:nested_match) {{
    nested: {
      inner_hits: {
          size: DataMagic::MAX_NESTED_RESULT
      },
      path: "2016.programs.cip_4_digit",
      query: {
        bool: {
          filter: [{
            bool: {
              must: [{
                match: { "2016.programs.cip_4_digit.code" => "1312" }
              }]
            }
          }]
        }
      }
    }
}}

  shared_examples "builds a query" do
    it "with a query section" do
      expect(query_hash[:query]).to eql expected_query
    end
    it "with query metadata" do
        expect(query_hash.reject { |k, _| k == :query }).to eql nested_meta
    end
  end

  describe "appropriately combines queries for nested and non-nested datatypes" do
    context "both queries are match queries" do
      subject {{ 
        "2016.programs.cip_4_digit.code" => "1312",
        "id" => "243744"
      }}

      let(:expected_query) {{
        bool: {
          must: { match: { "id" => "243744" }},
          filter: nested_match
        }
      }}

      it_correctly "builds a query"
    end

    context "non-nested query is an autocomplete query and nested query is a match query" do
      subject {{ 
        "2016.programs.cip_4_digit.code" => "1312",
        "school.name" => "arizona"
      }}

      let(:expected_query) {{
        bool: {
          must: non_nested_autocomplete,
          filter: nested_match
        }
      }}

      it_correctly "builds a query"


    end

    context "non-nested query is an range query and nested query is a match query" do
      subject {{ 
        "2016.programs.cip_4_digit.code" => "1312",
        "school.degrees_awarded.predominant__range" => "1..3"
      }}

      let(:expected_query) {{
        bool: {
          filter: [
            non_nested_range, 
            nested_match
          ]
        }
      }}

      it_correctly "builds a query"
    end

    context "query includes non-nested range query and autocomplete query and nested query is a match query" do
      subject {{ 
        "2016.programs.cip_4_digit.code" => "1312",
        "school.degrees_awarded.predominant__range" => "1..3",
        "school.name" => "arizona"
      }}

      let(:expected_query) {{
        bool: {
          filter: [
            non_nested_range, 
            nested_match,
            {
              bool: {
                must: non_nested_autocomplete
              }
            }
          ]
        }
      }}

      it_correctly "builds a query"
    end
  end
end