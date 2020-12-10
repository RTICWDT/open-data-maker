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

  shared_examples "builds a query" do
    it "with a query section" do
      expect(query_hash[:query]).to eql expected_query
    end
    it "with query metadata" do
        expect(query_hash.reject { |k, _| k == :query }).to eql nested_meta
    end
  end

  describe "alters query depending on the all_programs params that are passed" do
    context "in absence of all_programs param" do
      subject { { "2016.programs.cip_4_digit.code" => "1312" } }
      let(:expected_query) { 
        { 
          bool: {
            filter: {
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
          } 
        }
        } 
      }
      it_correctly "builds a query"
    end

    context "in presence of all_programs param" do
      subject {{ "2016.programs.cip_4_digit.code" => "1312" }}
      let(:options) {{ :all_programs => true }}

      let(:expected_query) {{ match: { "2016.programs.cip_4_digit.code" => "1312" }} }
      let(:nested_meta)    {{ post_es_response: {}, from: 0, size: 20, _source: {:exclude=>["_*"]} } }

      it_correctly "builds a query"
    end

    context "in presence of all_programs_nested param" do
      subject {{ "2016.programs.cip_4_digit.code" => "1312" }}
      let(:options) {{ :all_programs_nested => true, :fields => ["2016.programs.cip_4_digit.code.earnings.median_earnings"] }}

      let(:expected_query) { 
        { 
          bool: {
            filter: {
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
            } 
          }
        } 
      }
      let(:nested_meta) {{
        post_es_response: {:nested_fields_filter=>["2016.programs.cip_4_digit.code.earnings.median_earnings"]},
        from: 0,
        size: 20,
        _source: ["2016.programs.cip_4_digit.code.earnings.median_earnings"]
      }}

      it_correctly "builds a query"
    end
  end

  describe "builds correct nested query objects depending on terms passed" do
    context "for a single nested datatype query that takes an array of values" do
      subject { { "2016.programs.cip_4_digit.credential.level" => "[2,3,5]" } }
      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                },
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [
                      { "terms": { "2016.programs.cip_4_digit.credential.level" => [2, 3, 5]} }
                    ]
                  }
                }
              }
            } 
          }
        } 
      }
      it_correctly "builds a query"
    end

    context "when more than one terms and each term has a single value" do
      subject { { 
        "2016.programs.cip_4_digit.code" => "1312",
        "2016.programs.cip_4_digit.credential.level" => "2",
      } }
      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                },
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [
                      bool: {
                        must: [
                          { match: { "2016.programs.cip_4_digit.code" => "1312" }},
                          { match: { "2016.programs.cip_4_digit.credential.level" => "2" }}
                        ]
                      }
                    ]
                  }
                }
              }
            } 
          } 
        } 
      }
      it_correctly "builds a query"
      
    end

    context "when more than one term and each term takes an array of values" do
      subject { { 
        "2016.programs.cip_4_digit.credential.level" => "[2,3,5]",
        "2016.programs.cip_4_digit.code" => "[1312,4004]",
      } }
      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                },
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [
                      { "terms": { "2016.programs.cip_4_digit.credential.level" => [2, 3, 5]} },
                      { "terms": { "2016.programs.cip_4_digit.code" => [1312,4004]} }
                    ]
                  }
                }
              }
            }
          } 
        } 
      }
      it_correctly "builds a query"
    end

    context "when one term has an array of values and the other has a single value" do
      subject { { 
        "2016.programs.cip_4_digit.credential.level" => "[2,3,5]",
        "2016.programs.cip_4_digit.code" => "1312"
      } }
      let(:expected_query) { 
        { bool: { 
          filter: {
            nested: {
              inner_hits: {
                  size: DataMagic::MAX_NESTED_RESULT
              },
              path: "2016.programs.cip_4_digit",
              query: {
                bool: {
                  filter: [
                    { terms: { "2016.programs.cip_4_digit.credential.level" => [2, 3, 5]} },
                    { bool: { 
                        must: [{ 
                          match: { "2016.programs.cip_4_digit.code" => "1312" }
                        }]
                    }}
                  ]
                }
              }
            }
        } } } 
      }
      it_correctly "builds a query"
      
    end
  end


  describe "builds nested filter queries for terms that accept an array of values" do
    context "for a single nested datatype query term" do
      subject { { "2016.programs.cip_4_digit.credential.level" => "[2,3,5]" } }
      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                },
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [
                      { "terms": { "2016.programs.cip_4_digit.credential.level" => [2, 3, 5]} }
                    ]
                  }
                }
              }
            } 
          } 
        } 
      }
      it_correctly "builds a query"
    end
  end

  describe "builds queries that correctly organizes requested fields by datatype" do
    context "no fields are passed in the params" do
      subject {{}}
      let(:options) {{}}
      let(:source_value) { {:exclude=>["_*"]} }

      it "assigns a Hash with key 'exclude' to _source" do
        expect(query_hash[:_source]).to eql source_value
      end
    end

    context "only non-nested datatype fields are passed in params" do
      subject {{}}
      let(:fields_in_params) { ["school.name","id"] }
      let(:options) {{ :fields => fields_in_params }}
      let(:source_value) { false }

      it "assigns 'false' to _source" do
        expect(query_hash[:_source]).to eql source_value
      end

      it "assigns the fields to the query fields key" do
        expect(query_hash[:fields]).to eql fields_in_params
      end
    end

    
    context "only nested datatype fields are passed in params" do
      context "the query is NOT a nested query type" do
        subject {{}}
        let(:fields_in_params) { ["2016.programs.cip_4_digit.code.code"] }
        let(:options) {{ :fields => fields_in_params }}

        it "assigns the fields to _source" do
          expect(query_hash[:_source]).to eql fields_in_params
        end

        it "query fields key is empty" do
          expect(query_hash[:fields]).to be_nil
        end
      end

      context "the query is a nested query type" do
        subject {{ "2016.programs.cip_4_digit.code" => "1312" }}
        let(:fields_in_params) { ["2016.programs.cip_4_digit.code"] }
        let(:options) {{ :fields => fields_in_params }}
        let(:source_value) { false }

        it "assigns false to _source" do
          expect(query_hash[:_source]).to eql source_value
        end

        it "query fields key is empty" do
          expect(query_hash[:fields]).to be_nil
        end

        it "passes the nested fields to the query hash post_es_response key" do
          expect(query_hash[:post_es_response][:nested_fields_filter]).to eql fields_in_params
        end
      end
    end
  end

  describe "adds sort properties correctly" do
    let(:sort_str) { "2016.programs.cip_4_digit.earnings.median_earnings" }
    let(:options) {{ :sort => sort_str }}

    context "single sort field is a nested datatype" do
      subject {{}}
      let(:nested_sort_filter) {[
        sort_str => {
          order: "asc",
          nested_path: "2016.programs.cip_4_digit",
          nested_filter: nil
        }
      ]}

      it "includes the nested sort field term" do
        expect(query_hash[:sort][0].keys[0]).to eql sort_str
      end

      it "assigns the nested path" do
        expect(query_hash[:sort][0][sort_str][:nested_path]).to eql "2016.programs.cip_4_digit"
      end

      it "builds the correct nested sort hash structure" do
        expect(query_hash[:sort]).to eql nested_sort_filter
      end
    end

    context "sort field and query term are nested datatype fields" do
      subject {{ "2016.programs.cip_4_digit.code" => "1312" }}
      let(:nested_sort_filter) {[
        sort_str => {
          order: "asc",
          nested_path: "2016.programs.cip_4_digit",
          nested_filter: {
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
      ]}

      it "builds the correct nested sort hash structure" do
        expect(query_hash[:sort]).to eql nested_sort_filter
      end
    end
  end

  describe "handles range queries for nested data types" do
    context "a single nested datatype is a range query with min and max defined" do
      subject {{ "2016.programs.cip_4_digit.credential.level__range" => "6..8" }}

      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [{
                      or: [{
                        range: {
                          "2016.programs.cip_4_digit.credential.level" => { "gte": "6", "lte": "8" }
                        }
                      }]
                    }]
                  }
                },
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                }
              }
            }
          }
        } 
      }

      it_correctly "builds a query"
    end

    context "a single nested datatype is a range query with only min defined" do
      subject {{ "2016.programs.cip_4_digit.credential.level__range" => "6.." }}

      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [{
                      or: [{
                        range: {
                          "2016.programs.cip_4_digit.credential.level" => { "gte": "6" }
                        }
                      }]
                    }]
                  }
                },
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                }
              }
            }
          }
        } 
      }

      it_correctly "builds a query"
    end

    context "a single nested datatype is a range query with only max defined" do
      subject {{ "2016.programs.cip_4_digit.credential.level__range" => "..8" }}

      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [{
                      or: [{
                        range: {
                          "2016.programs.cip_4_digit.credential.level" => { "lte": "8" }
                        }
                      }]
                    }]
                  }
                },
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                }
              }
            }
          }
        } 
      }

      it_correctly "builds a query"
    end

    context "a nested datatype range query is combined with and nested match query" do
      subject {{ 
        "2016.programs.cip_4_digit.credential.level__range" => "6..8",
        "2016.programs.cip_4_digit.code" => "1312"
      }}

      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [{
                      or: [{
                        range: {
                          "2016.programs.cip_4_digit.credential.level" => { "gte": "6", "lte": "8" }
                        }
                      }]
                    }, {
                      bool: {
                        must: [{
                          match: { "2016.programs.cip_4_digit.code" => "1312" }
                        }]
                      }
                    }]
                  }
                },
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                }
              }
            }
          }
        } 
      }

      it_correctly "builds a query"
    end
  end

  describe "handles not queries for nested data types" do
    context "a single nested datatype is a not query" do
      subject {{ "2016.programs.cip_4_digit.credential.level__not" => "3" }}

      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [{
                      bool: {
                        must_not: [{
                          match: { "2016.programs.cip_4_digit.credential.level" => "3" }
                        }]
                      }
                    }]
                  }
                },
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                }
              }
            }
          }
        } 
      }

      it_correctly "builds a query"
    end

    context "a single nested datatype is a not query with a list of values" do
      subject {{ "2016.programs.cip_4_digit.credential.level__not" => [2,3,5] }}

      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [{
                      bool: {
                        must_not: [{
                          terms: { "2016.programs.cip_4_digit.credential.level" => [2,3,5] }
                        }]
                      }
                    }]
                  }
                },
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                }
              }
            }
          }
        } 
      }

      it_correctly "builds a query"
    end

    context "a nested datatype not query is combined with a match query" do
      subject {{ 
        "2016.programs.cip_4_digit.credential.level__not" => [2,3,5],
        "2016.programs.cip_4_digit.code" => "1312"
      }}

      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [{
                      bool: {
                        must_not: [{
                          terms: { "2016.programs.cip_4_digit.credential.level" => [2,3,5] }
                        }]
                      }
                    }, {
                      bool: {
                        must: [{
                          match: { "2016.programs.cip_4_digit.code" => "1312" }
                        }],
                      }
                    }]
                  }
                },
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                }
              }
            }
          }
        } 
      }

      it_correctly "builds a query"
    end

    context "a nested datatype not query is combined with a range query" do
      subject {{ 
        "2016.programs.cip_4_digit.earnings.median_earnings__range" => "70000..",
        "2016.programs.cip_4_digit.credential.level__not" => 8
      }}

      let(:expected_query) { 
        { 
          bool: { 
            filter: {
              nested: {
                path: "2016.programs.cip_4_digit",
                query: {
                  bool: {
                    filter: [{
                      or: [{
                        range: {
                          "2016.programs.cip_4_digit.earnings.median_earnings" => { "gte": "70000" }
                        }
                      }]
                    },{
                      bool: {
                        must_not: [{
                          match: { "2016.programs.cip_4_digit.credential.level" => 8 }
                        }],
                      }
                    }]
                  }
                },
                inner_hits: {
                    size: DataMagic::MAX_NESTED_RESULT
                }
              }
            }
          }
        } 
      }

      it_correctly "builds a query"
    end
  end
end