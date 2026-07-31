require "data_index_config"

RSpec.describe DataIndexConfig do
  let(:config) { described_class.load }

  def jekyll_index(repo)
    YAML.safe_load(config.render_repo(repo)).fetch("jekyll-index")
  end

  describe "#render_repo" do
    it "renders a flat v1 flavor without pubid keys (3gpp)" do
      parsed = YAML.safe_load(config.render_repo("3gpp"))
      expect(parsed["title"]).to eq("3GPP Index")
      expect(parsed["paginate"]).to eq(100)
      ji = parsed.fetch("jekyll-index")
      expect(ji["source"]).to eq("index-v1.yaml")
      expect(ji["baseurl"])
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-3gpp/v2/")
      expect(ji["add_type_to_reference"]).to be(true)
      expect(ji).not_to have_key("pubid_class")
      expect(ji).not_to have_key("pubid_require")
    end

    it "renders a v2 pubid flavor with the external Identifier class (iso)" do
      ji = jekyll_index("iso")
      expect(ji["source"]).to eq("index-v2.yaml")
      expect(ji["baseurl"])
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-iso/v2/")
      expect(ji["pubid_class"]).to eq("Pubid::Iso::Identifier")
      expect(ji["pubid_require"]).to eq("pubid")
    end

    it "keeps pubid keys for a v1-named but pubid-structured flavor (jcgm)" do
      ji = jekyll_index("jcgm")
      expect(ji["source"]).to eq("index-v1.yaml")
      expect(ji["pubid_class"]).to eq("Pubid::Jcgm::Identifier")
      expect(ji["pubid_require"]).to eq("pubid")
    end

    it "uses index-v3 for iho" do
      ji = jekyll_index("iho")
      expect(ji["source"]).to eq("index-v3.yaml")
      expect(ji["pubid_class"]).to eq("Pubid::Iho::Identifier")
    end

    it "uses the repo's real default branch in baseurl (adobe -> main)" do
      expect(jekyll_index("adobe")["baseurl"])
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-adobe/main/")
    end

    it "applies one uniform favicon to every repo" do
      favicons = config.repos.map { |e| jekyll_index(e["repo"])["favicon"] }.uniq
      expect(favicons.size).to eq(1)
      expect(favicons.first).to match(%r{\Ahttps://.+favicon})
    end

    it "never emits a pubid_class with a leading '::' (const_get rejects it)" do
      config.repos.each do |e|
        ji = jekyll_index(e["repo"])
        expect(ji["pubid_class"]).not_to start_with("::") if ji.key?("pubid_class")
      end
    end

    it "escapes single quotes so an awkward value still yields valid YAML" do
      cfg = described_class.new(
        { "paginate" => 100, "pubid_require" => "pubid",
          "favicon" => "https://x/it's.ico",
          "baseurl_template" => "https://raw/%<repo>s/%<branch>s/",
          "description_template" => "Welcome to the %<display>s standards index site!" },
        [{ "repo" => "q", "display" => "Q", "source" => "index-v2.yaml",
           "branch" => "main", "pubid_class" => "Pubid::Q::Identifier" }],
      )
      parsed = YAML.safe_load(cfg.render_repo("q"))
      expect(parsed["jekyll-index"]["favicon"]).to eq("https://x/it's.ico")
    end

    it "produces valid YAML with the expected top-level keys for every repo" do
      config.repos.each do |e|
        parsed = YAML.safe_load(config.render_repo(e["repo"]))
        expect(parsed.keys).to include("title", "description", "paginate", "jekyll-index")
      end
    end
  end

  describe "configs.yml data" do
    it "covers exactly the 25 target repos with no duplicates" do
      repos = config.repos.map { |e| e["repo"] }
      expect(repos.size).to eq(25)
      expect(repos.uniq.size).to eq(25)
      expect(repos).to include("iso", "ieee", "jis", "adobe", "easc", "gost", "jcgm", "oiml")
      expect(repos).not_to include("sdo", "ietf", "misc", "ids", "oasis", "w3c")
    end

    it "gives every entry the required fields" do
      config.repos.each do |e|
        expect(e["repo"]).to be_a(String)
        expect(e["display"]).to be_a(String)
        expect(e["source"]).to match(/\Aindex-v[123]\.yaml\z/)
        expect(%w[main v2 master]).to include(e["branch"])
      end
    end
  end
end
