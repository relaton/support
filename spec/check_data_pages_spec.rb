# Offline unit tests for the URL builders behind bin/check-data-pages. The live
# HTTP 200 check lives only in the executable (it needs the rollout to have
# landed); here we pin only the URL construction so the suite never touches the
# network.
require "data_index_config"

RSpec.describe "DataIndexConfig Pages URLs" do
  let(:config) { DataIndexConfig.load }

  describe "#pages_url" do
    it "builds the GitHub project-pages URL for a repo" do
      expect(config.pages_url("iso"))
        .to eq("https://relaton.github.io/relaton-data-iso/")
    end

    it "honors a custom --base host without doubling the slash" do
      expect(config.pages_url("iso", base: "https://data.relaton.org/"))
        .to eq("https://data.relaton.org/relaton-data-iso/")
    end

    it "raises for an unknown repo" do
      expect { config.pages_url("nope") }.to raise_error(ArgumentError, /unknown repo/)
    end
  end

  describe "#raw_index_url" do
    it "joins the repo baseurl (real default branch) with the published source" do
      expect(config.raw_index_url("iso"))
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-iso/v2/index-v2.yaml")
    end

    it "uses the repo's own default branch (adobe -> main) and source" do
      expect(config.raw_index_url("adobe"))
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-adobe/main/index-v2.yaml")
    end

    it "uses index-v3 for iho" do
      expect(config.raw_index_url("iho")).to end_with("/v2/index-v3.yaml")
    end
  end
end
