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

  # The site's own manifest names the index it published — `relaton index`
  # resolved it from the flavor's `INDEXFILE` — so the checker reads that name
  # and checks exactly the URL the relaton gems fetch. It guesses nothing.
  describe "#manifest_url" do
    it "points at the machine index manifest on the Pages site" do
      expect(config.manifest_url("iso"))
        .to eq("https://relaton.github.io/relaton-data-iso/index/manifest.json")
    end

    it "honors a custom --base host" do
      expect(config.manifest_url("iso", base: "https://data.relaton.org"))
        .to eq("https://data.relaton.org/relaton-data-iso/index/manifest.json")
    end

    it "raises for an unknown repo" do
      expect { config.manifest_url("nope") }.to raise_error(ArgumentError, /unknown repo/)
    end
  end

  describe ".index_from_manifest" do
    it "reads the monolith base name the site published" do
      body = %({"version":2,"index":"index-v2","count":10,"shards":8})

      expect(DataIndexConfig.index_from_manifest(body)).to eq("index-v2")
    end

    it "returns nil for a body that names no index" do
      expect(DataIndexConfig.index_from_manifest(%({"version":2,"count":10}))).to be_nil
    end

    it "returns nil for a blank or malformed body" do
      # A 404 page, an empty response and a truncated file all arrive here as
      # text. None of them may crash the checker or name an index.
      expect(DataIndexConfig.index_from_manifest("")).to be_nil
      expect(DataIndexConfig.index_from_manifest(nil)).to be_nil
      expect(DataIndexConfig.index_from_manifest("<html>404</html>")).to be_nil
      expect(DataIndexConfig.index_from_manifest(%({"index":))).to be_nil
    end

    it "rejects an index name that is not a plain file name" do
      # The name is pasted into a URL, so a path segment or a blank string must
      # not become one.
      expect(DataIndexConfig.index_from_manifest(%({"index":"../secrets"}))).to be_nil
      expect(DataIndexConfig.index_from_manifest(%({"index":"  "}))).to be_nil
      expect(DataIndexConfig.index_from_manifest(%({"index":42}))).to be_nil
    end

    it "rejects a name that already carries its extension" do
      # #raw_index_url appends ".yaml". Accepting "index-v2.yaml" here would
      # build "index-v2.yaml.yaml" and report a healthy site as a 404.
      expect(DataIndexConfig.index_from_manifest(%({"index":"index-v2.yaml"}))).to be_nil
      expect(DataIndexConfig.index_from_manifest(%({"index":"index-v2.zip"}))).to be_nil
    end
  end

  describe "#raw_index_url" do
    it "joins the repo baseurl with the name the manifest gave" do
      expect(config.raw_index_url("iso", "index-v2"))
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-iso/v2/index-v2.yaml")
    end

    it "uses the repo's own default branch (adobe -> main)" do
      expect(config.raw_index_url("adobe", "index-v7"))
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-adobe/main/index-v7.yaml")
    end

    it "raises for an unknown repo" do
      expect { config.raw_index_url("nope", "index-v2") }
        .to raise_error(ArgumentError, /unknown repo/)
    end
  end
end
