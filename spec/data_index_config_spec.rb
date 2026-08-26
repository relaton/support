require "data_index_config"

RSpec.describe DataIndexConfig do
  let(:config) { described_class.load }

  # configs.yml reaches the live Pages build only through #branding (run by
  # bin/index-branding from the "Resolve branding" step of data-deploy.yml) and
  # bin/check-data-pages's #raw_index_urls. Both are asserted here through the
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
      overridden = %w[iana ids ietf itu oasis w3c]
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

  describe "#raw_index_urls" do
    # configs.yml names no index file. Which one a repo publishes is a fact on
    # raw.githubusercontent.com, so bin/check-data-pages probes the candidates
    # newest-first and takes the first 200 rather than reading a hand-kept key.
    it "offers every index name on the repo's real default branch (3gpp -> v2)" do
      expect(config.raw_index_urls("3gpp")).to eq(
        %w[
          https://raw.githubusercontent.com/relaton/relaton-data-3gpp/v2/index-v3.yaml
          https://raw.githubusercontent.com/relaton/relaton-data-3gpp/v2/index-v2.yaml
          https://raw.githubusercontent.com/relaton/relaton-data-3gpp/v2/index-v1.yaml
        ],
      )
    end

    it "uses the repo's own default branch (iala -> main)" do
      expect(config.raw_index_urls("iala"))
        .to all(start_with("https://raw.githubusercontent.com/relaton/relaton-data-iala/main/"))
    end

    it "orders the candidates newest first" do
      # The order is the whole safeguard, so pin it. A repo mid-migration can
      # serve two names at once — relaton-data-bipm serves index-v1 and
      # index-v2 today — and probing oldest-first would report the one it is
      # retiring. The list is the same for every repo, so any one shows it.
      expect(config.raw_index_urls("iho").map { |u| u.split("/").last })
        .to eq(%w[index-v3.yaml index-v2.yaml index-v1.yaml])
    end

    it "raises for an unknown repo" do
      expect { config.raw_index_urls("nope") }.to raise_error(ArgumentError, /unknown repo/)
    end
  end

  describe "#first_live_index" do
    # The choosing logic bin/check-data-pages runs, with the HTTP supplied by the
    # caller so the suite stays offline. The executable passes its own
    # http_status; here a hash stands in for the fleet's real responses.
    def pick(statuses)
      config.first_live_index("bipm") { |url| statuses.fetch(url.split("/").last) }
    end

    it "takes the newest index a repo serves, not the oldest" do
      # What relaton-data-bipm looks like today: it publishes both.
      status, url = pick("index-v3.yaml" => 404, "index-v2.yaml" => 200, "index-v1.yaml" => 200)

      expect(status).to eq(200)
      expect(url).to end_with("/index-v2.yaml")
    end

    it "stops at the first 200 rather than probing the rest" do
      probed = []
      status, = config.first_live_index("bipm") do |url|
        probed << url.split("/").last
        200
      end

      expect(status).to eq(200)
      expect(probed).to eq(%w[index-v3.yaml])
    end

    it "finds an index no row could have named (ietf moved v1 -> v2)" do
      status, url = pick("index-v3.yaml" => 404, "index-v2.yaml" => 200, "index-v1.yaml" => 404)

      expect(status).to eq(200)
      expect(url).to end_with("/index-v2.yaml")
    end

    it "reports the last candidate when a repo serves none" do
      # Not an assertion that the repo should serve index-v1: it is simply the
      # last status the probe saw, so the caller has one to print.
      # bin/check-data-pages prints the full candidate list alongside it.
      status, url = pick("index-v3.yaml" => 404, "index-v2.yaml" => 404, "index-v1.yaml" => 404)

      expect(status).to eq(404)
      expect(url).to end_with("/index-v1.yaml")
    end

    it "does not treat a non-200 such as a 403 as live" do
      status, = pick("index-v3.yaml" => 403, "index-v2.yaml" => 403, "index-v1.yaml" => 403)

      expect(status).to eq(403)
    end
  end

  describe "configs.yml data" do
    it "covers exactly the 31 repos with no duplicates" do
      repos = config.repos.map { |e| e["repo"] }
      expect(repos.size).to eq(31)
      expect(repos.uniq.size).to eq(31)
      expect(repos).to include("iso", "ieee", "jis", "adobe", "easc", "gost", "jcgm", "oiml", "iala")
      expect(repos).to include("ids", "oasis", "w3c") # already-live, folded in
      # Both ITU rows: `itu` is the combined ITU-R + ITU-T corpus, `itu-r` the
      # ITU-R-only repo the relaton gem still consumes. Neither is a typo for
      # the other, and dropping either silently 404s a site.
      expect(repos).to include("itu", "itu-r")
      # ietf was the one repo Cimas synced deploy.yml into with no row here. It
      # publishes an index since migrating to Relaton::Ietf::DataFetcher, so the
      # exclusion is lifted and this file now covers the whole synced fleet.
      expect(repos).to include("ietf")
      expect(repos).not_to include("sdo", "misc")
    end

    it "gives every entry the required fields" do
      config.repos.each do |e|
        expect(e["repo"]).to be_a(String)
        expect(e["display"]).to be_a(String)
        expect(%w[main v2 master]).to include(e["branch"])
      end
    end

    it "names no index file, so no row can drift from what its repo publishes" do
      # `source:` used to pin the index each repo served. It was a hand-copied
      # echo of a fact the remote already holds, and it drifted twice: iana led
      # its publish, ietf followed one that had been deleted. The checker now
      # discovers the index, so the key must not creep back.
      carrying = config.repos.select { |e| e.key?("source") }.map { |e| e["repo"] }

      expect(carrying).to be_empty,
                          "these rows still carry a `source` key: #{carrying.join(', ')}"
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
