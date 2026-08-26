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

  describe "#raw_index_urls" do
    it "joins the repo baseurl (real default branch) with every index name" do
      expect(config.raw_index_urls("iso")).to eq(
        %w[
          https://raw.githubusercontent.com/relaton/relaton-data-iso/v2/index-v3.yaml
          https://raw.githubusercontent.com/relaton/relaton-data-iso/v2/index-v2.yaml
          https://raw.githubusercontent.com/relaton/relaton-data-iso/v2/index-v1.yaml
        ],
      )
    end

    it "uses the repo's own default branch (adobe -> main)" do
      expect(config.raw_index_urls("adobe")).to eq(
        %w[
          https://raw.githubusercontent.com/relaton/relaton-data-adobe/main/index-v3.yaml
          https://raw.githubusercontent.com/relaton/relaton-data-adobe/main/index-v2.yaml
          https://raw.githubusercontent.com/relaton/relaton-data-adobe/main/index-v1.yaml
        ],
      )
    end

    it "raises for an unknown repo" do
      expect { config.raw_index_urls("nope") }.to raise_error(ArgumentError, /unknown repo/)
    end
  end
end
