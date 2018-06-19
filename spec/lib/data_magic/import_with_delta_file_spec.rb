require 'spec_helper'
require 'data_magic'

describe "delta update" do

  before :example do
    DataMagic.destroy
    ENV['DATA_PATH'] = './spec/fixtures/nested_delta_files'
    DataMagic.config = DataMagic::Config.new
    DataMagic.import_with_dictionary
    DataMagic.import_with_delta({delta_original: 'latest-school-data.csv', delta_update: 'latest-school-data_update1.csv'})
  end
  after :example do
    DataMagic.destroy
  end
  let(:query)   { {} }
  let(:sort)    { nil }
  let(:result)  { DataMagic.search(query, sort: sort) }
  let(:first)   { result['results'].first }
  let(:id_one)   { result['results'].find { |item| item['id'] == '1' } }
  let(:total)   { result['metadata']['total'] }

  it "updates one document per unique id" do
    expect(total).to eq(11)
  end

  it "updates root document :delta_only fields" do
    expect(id_one['id']).to eq('1')
    expect(id_one['under_investigation']).to eq(1)
  end

  it "does not update root document fields not specified in :delta_only" do
    expect(id_one['name']).to eq('Reichert University')
  end

  it "updates nested documents per unique id" do
    expect(id_one['latest']).to_not be_nil
    expect(id_one['latest']['earnings']['6_yrs_after_entry']['median']).to eq(30000)
  end

  it "does not update nested documents in non-delta files" do
    expect(id_one['id']).to eq('1')
    expect(id_one['2013']).to_not be_nil
    expect(id_one['2013']['earnings']['6_yrs_after_entry']['median']).to eq(26318)
  end

  context "can import a subset of fields" do
    context "and when searching for a field value" do
      let(:query) { {zipcode: "35762"} }
      it "and doesn't find column" do
        expect(total).to eq(0)
      end
    end
    it "and doesn't include extra field" do
      expect(first['zipcode']).to be(nil)
    end
  end

  context "when searching on a nested field" do
    let(:query) { { 'latest.earnings.6_yrs_after_entry.median' => 30000 } }
    it "can find the correct results" do
      expect(total).to eq(1)
      expect(first['latest']['earnings']['6_yrs_after_entry']).to eq({"percent_gt_25k"=>0.53, "median"=>30000})
    end
  end

  context "when sorting by a nested field" do
    let(:sort) { 'latest.earnings.6_yrs_after_entry.median' }
    it "can find the right first result" do
      expect(total).to eq(11)
      expect(first['latest']['earnings']['6_yrs_after_entry']).to eq({"percent_gt_25k"=>0.1, "median"=>1900})
    end
  end
end


