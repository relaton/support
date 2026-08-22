require "data_index_config"

RSpec.describe DataIndexConfig do
  let(:config) { described_class.load }

  # configs.yml reaches the live Pages build only through #branding (run by
  # bin/index-branding from the "Resolve branding" step of data-deploy.yml) and
  # bin/check-data-pages's #raw_index_url. Both are asserted here through the
  # public surface, because the rendered Jekyll _config.yml they used to be
  # cross-checked against is gone.
  def branding(repo)
    config.branding("relaton/relaton-data-#{repo}")
  end

  describe "#branding" do
    it "titles a site from `display` (3gpp)" do
      expect(branding("3gpp")["title"]).to eq("3GPP Index")
    end

    it "applies the default favicon to repos without an override" do
      # The convention is the SDO's own icon where there is a stable URL for one,
      # so this roster grows. Adding a `favicon:` to a row means adding it here.
      overridden = %w[iana ids itu oasis w3c]
      default_favicon = config.defaults.fetch("favicon")

      config.repos.reject { |e| overridden.include?(e["repo"]) }.each do |e|
        expect(branding(e["repo"])["favicon"]).to eq(default_favicon),
                                                 "#{e['repo']} should inherit the default favicon"
      end

      overridden.each do |repo|
        expect(branding(repo)["favicon"]).not_to eq(default_favicon),
                                                 "#{repo} should carry its own favicon"
      end
    end

    it "honors a per-repo favicon override (w3c)" do
      expect(branding("w3c")["favicon"])
        .to eq("https://www.w3.org/assets/logos/w3c/w3c-no-bars.svg")
    end

    it "carries iana's branding" do
      # Taken from the relaton-data-iana caller prepared alongside the row and
      # not live anywhere else — this is an editorial choice, not a recovery.
      # Recorded here rather than in that caller because a `cimas sync` would
      # drop a `with:` block without trace.
      expect(branding("iana")["favicon"]).to eq("https://www.iana.org/favicon.ico")
      expect(branding("iana")["description"])
        .to start_with("Protocol parameter registries represent the authoritative record")
    end

    it "honors a per-repo description override (ids)" do
      expect(branding("ids")["description"])
        .to eq("Bibliographic data information for Internet-Drafts in Relaton format")
    end

    it "templates the description for repos without an override (iso)" do
      expect(branding("iso")["description"])
        .to eq("Welcome to the ISO standards index site!")
    end
  end

  describe "#raw_index_url" do
    it "joins the repo's real default branch and published index (3gpp)" do
      expect(config.raw_index_url("3gpp"))
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-3gpp/v2/index-v1.yaml")
    end

    it "renders the iala row: v2 source, main branch" do
      expect(config.raw_index_url("iala"))
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-iala/main/index-v2.yaml")
    end

    it "points iana at index-v2, ahead of its data repo's publish" do
      # `Relaton::Iana::INDEXFILE` is index-v2 in relaton/relaton@main, so this
      # row names index-v2 too. relaton-data-iana@v2 has not published it yet
      # (measured 2026-08-22: index-v2.yaml 404s, index-v1.yaml is 200), so
      # bin/check-data-pages reports a KNOWN 404 for iana until that lands.
      # Nothing automated reads this: data-deploy.yml takes only branding from
      # configs.yml, and check-data-pages is a hand-run gate.
      expect(config.raw_index_url("iana"))
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-iana/v2/index-v2.yaml")
    end
  end

  describe "configs.yml data" do
    it "covers exactly the 30 repos with no duplicates" do
      repos = config.repos.map { |e| e["repo"] }
      expect(repos.size).to eq(30)
      expect(repos.uniq.size).to eq(30)
      expect(repos).to include("iso", "ieee", "jis", "adobe", "easc", "gost", "jcgm", "oiml", "iala")
      expect(repos).to include("ids", "oasis", "w3c") # already-live, folded in
      # Both ITU rows: `itu` is the combined ITU-R + ITU-T corpus, `itu-r` the
      # ITU-R-only repo the relaton gem still consumes. Neither is a typo for
      # the other, and dropping either silently 404s a site.
      expect(repos).to include("itu", "itu-r")
      expect(repos).not_to include("sdo", "ietf", "misc")
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

RSpec.describe "the retired Jekyll _config.yml machinery" do
  # support#58 (relaton/relaton#83) replaced the Jekyll Pages build with
  # `relaton index`, which reads each data repo's own `data/` folder. These keys
  # and this method fed only that build. Measured before their removal: no
  # relaton-data-* repo carries a committed `_config.yml`, so the generated
  # snapshot never reached a consumer.
  #
  # This guards the removal rather than the removed behavior: the keys are cheap
  # to re-add by copying a neighbouring row, and nothing would fail if they came
  # back dead.
  let(:config) { DataIndexConfig.load }

  it "is gone from DataIndexConfig's surface" do
    expect(DataIndexConfig.instance_methods).not_to include(:render, :render_repo)
  end

  it "leaves no Jekyll-only key in configs.yml defaults" do
    expect(config.defaults.keys).not_to include("paginate", "pubid_require")
  end

  it "leaves no Jekyll-only key on any repo row" do
    config.repos.each do |entry|
      expect(entry.keys).not_to include("pubid_class", "pubid_require"),
                                "#{entry.fetch('repo')} still carries a pubid key"
    end
  end

  it "ships no generator and no generated snapshot" do
    root = File.expand_path("..", __dir__)
    expect(File.exist?(File.join(root, "bin/gen-data-index-config"))).to be(false)
    expect(Dir.exist?(File.join(root, "data-index/generated"))).to be(false)
  end
end
