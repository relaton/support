# Offline unit tests for CimasConfig, the reader behind bin/cimas-orphan-audit.
# The network half (listing and fetching each destination repo) lives only in
# the executable; the orphan decision itself is pure logic and is pinned here,
# because that decision is what deletes files.
require "cimas_config"
# For the .raw_url examples only: they assert that what it builds is something
# URI.parse accepts, which is the bug that method exists to prevent. The
# library itself needs no URI; bin/cimas-orphan-audit requires it for Net::HTTP.
require "uri"

RSpec.describe CimasConfig do
  let(:config) { described_class.load }

  # A minimal stand-in for a destination repo: the file bodies bin/ fetches,
  # keyed by their path in that repo.
  def blobs(pairs)
    pairs
  end

  describe ".load" do
    it "reads every repositories: entry of the shipped cimas.yml" do
      expect(config.names.size).to eq(99)
    end

    it "reads no duplicate name" do
      expect(config.names.uniq).to eq(config.names)
    end
  end

  describe "#files" do
    it "reads a repo's destination -> template mapping" do
      expect(config.files("relaton-models")).to eq(
        "Gemfile" => "gh-actions/model/Gemfile",
        "Makefile" => "gh-actions/model/Makefile",
        ".github/workflows/make.yml" => "gh-actions/model/make.yml",
      )
    end

    it "reads a `files:` with no value as an empty mapping" do
      # Cimas::Repository normalises nil and [] to {}. Pin it: this is why a
      # repo with an empty `files:` has every header-carrying file orphaned.
      expect(config.files("relaton-model-jis")).to eq({})
    end

    it "raises for an unknown repo" do
      expect { config.files("nope") }.to raise_error(ArgumentError, /unknown repo/)
    end
  end

  describe "#slug" do
    it "derives the GitHub slug from the remote, not the key" do
      # Two cimas.yml keys do not match their repo name. An audit that built
      # the URL from the key would query a repo that does not exist.
      expect(config.slug("loc_mods")).to eq("relaton/loc-mods")
      expect(config.slug("loc_marc")).to eq("relaton/loc-marc")
    end

    it "derives the slug for an ordinary entry" do
      expect(config.slug("relaton-models")).to eq("relaton/relaton-models")
    end
  end

  describe "#resolve" do
    it "expands a group name, as cimas -g does" do
      expect(config.resolve(["data"])).to include("relaton-data-iso")
    end

    it "expands `all` to every repo" do
      expect(config.resolve(["all"])).to eq(config.names)
    end

    it "takes a bare repo name" do
      expect(config.resolve(["relaton-models"])).to eq(["relaton-models"])
    end

    it "expands an empty selection to every repo" do
      # The audit mutates nothing, so it defaults to the whole fleet. `cimas`
      # itself refuses an unscoped run, because its wave does mutate.
      expect(config.resolve([])).to eq(config.names)
    end

    it "raises for a name that is neither a group nor a repo" do
      expect { config.resolve(["nope"]) }.to raise_error(ArgumentError, /unknown repo/)
    end
  end

  describe "#ungrouped" do
    # The only mapping an ungrouped repo may carry. `-g all` reaches these
    # repos, and no fleet wave needs them.
    gem_pair = [
      ".github/workflows/rake.yml",
      ".github/workflows/release.yml",
    ].freeze

    it "names every repo that no group lists" do
      # `cimas -g <group>` never reaches these, so a wave scoped by group has a
      # different blast radius from `-g all`. The audit warns about it. The
      # list is asserted whole so a new ungrouped repo is a visible edit.
      #
      # An earlier version of this example claimed none of these mapped a file.
      # That was never true: all four map the gem pair above, and a fifth,
      # rawdata-bipm-metrologia, mapped crawler.yml and keep-alive.yml. The
      # wrong comment is what made the hole look harmless, so the next example
      # asserts the property this one only claimed.
      expect(config.ungrouped).to eq(
        %w[relaton-core ieee-idams loc_marc loc_mods],
      )
    end

    it "leaves ungrouped no repo that maps a fleet file" do
      # rawdata-bipm-metrologia sat here mapping keep-alive.yml, so no
      # `-g <group>` wave could reach it, and the 2026-09-01 keep-alive outage
      # was unrepairable there by any group-scoped sync. An ungrouped repo that
      # maps a fleet file IS that hole. The four that remain map only the gem
      # pair, which is a separate question: grouping them would change what a
      # `flavors` wave reaches.
      offenders = config.ungrouped.reject do |name|
        config.files(name).keys.sort == gem_pair
      end
      detail = offenders.map { |name| "#{name} (#{config.files(name).keys.join(', ')})" }

      expect(offenders).to be_empty,
                           "these repos are in no group yet map a fleet file, so no " \
                           "group-scoped wave reaches them: #{detail.join('; ')}"
    end
  end

  describe "#all_target_paths" do
    it "lists every destination path any repo maps" do
      expect(config.all_target_paths).to eq(
        [
          ".github/workflows/check-index.yml",
          ".github/workflows/check_data.yml",
          ".github/workflows/crawler.yml",
          ".github/workflows/deploy.yml",
          ".github/workflows/keep-alive.yml",
          ".github/workflows/make.yml",
          ".github/workflows/rake.yml",
          ".github/workflows/release.yml",
          "Gemfile",
          "Makefile",
        ],
      )
    end
  end

  describe "#template_path" do
    it "resolves a template under the master directory" do
      expect(File.exist?(config.template_path("gh-actions/model/Gemfile"))).to be true
    end

    it "resolves every template the config maps" do
      missing = config.names.flat_map { |n| config.files(n).values }.uniq
                      .reject { |src| File.exist?(config.template_path(src)) }
      expect(missing).to be_empty,
                         "cimas.yml maps template(s) that do not exist: #{missing.join(', ')}"
    end
  end

  describe ".raw_url" do
    # bin/cimas-orphan-audit reads a file over --max-bytes as header bytes only,
    # over raw.githubusercontent.com with a Range request. It built that URL by
    # interpolation, so a path containing a space raised URI::InvalidURIError,
    # the blanket `rescue StandardError` turned it into nil, and the audit
    # reported the file as unreadable — which is an exit-1 condition. Adding
    # NIST-Tech-Pubs to cimas.yml surfaced it: that repo holds a 2.8 MB
    # `NIST-TS-itables-compact (1).html`, so the audit failed on every run for a
    # reason that had nothing to do with any Cimas file.
    it "escapes a path that needs it" do
      url = described_class.raw_url("relaton/NIST-Tech-Pubs", "nist-pages",
                                    "NIST-TS-itables-compact (1).html")

      # The parentheses are escaped too. They are legal unescaped in a path, so
      # this is stricter than it has to be; both forms answer 206 to the Range
      # request the audit makes. Pinned as produced rather than as minimal.
      expect(url).to eq(
        "https://raw.githubusercontent.com/relaton/NIST-Tech-Pubs/nist-pages/" \
        "NIST-TS-itables-compact%20%281%29.html",
      )
      expect { URI.parse(url) }.not_to raise_error
    end

    it "leaves an ordinary path alone" do
      # The slash separators must survive, or every nested path 404s.
      expect(described_class.raw_url("relaton/relaton-data-iso", "v2",
                                     ".github/workflows/keep-alive.yml"))
        .to eq("https://raw.githubusercontent.com/relaton/relaton-data-iso/v2/" \
               ".github/workflows/keep-alive.yml")
    end

    it "escapes the characters that would end the path early" do
      # `URI::DEFAULT_PARSER.escape` leaves `?` and `&` raw, so a file named
      # `a?b.html` would split into a path and a query string and fetch
      # something else entirely. A `+` must not survive either: CGI.escape
      # writes a space as `+`, so a literal one has to be encoded to stay
      # distinguishable.
      url = described_class.raw_url("relaton/x", "main", "a?b&c+d#e.html")

      expect(url).to end_with("/main/a%3Fb%26c%2Bd%23e.html")
    end

    it "encodes a percent that is already in the name" do
      # These paths come from a GitHub contents listing, so a `%20` in one is a
      # literal percent-two-zero in the filename, not an escape to preserve.
      expect(described_class.raw_url("relaton/x", "main", "a%20b.html"))
        .to end_with("/main/a%2520b.html")
    end
  end

  describe ".generated?" do
    it "is true when the marker opens the file" do
      expect(described_class.generated?("#{described_class::GENERATED_HEADER}\nname: x\n")).to be true
    end

    it "is true when the marker ends inside the first 500 bytes" do
      pad = "# #{'x' * (described_class::HEADER_READ_BYTES - described_class::GENERATED_HEADER_MARKER.size - 3)}\n"
      expect(described_class.generated?(pad + described_class::GENERATED_HEADER_MARKER)).to be true
    end

    it "is false when the marker starts after the first 500 bytes" do
      # cimas reads HEADER_READ_BYTES and no more, so a marker below that cut
      # does not make a file cimas-managed. Pin the boundary.
      padded = ("x" * described_class::HEADER_READ_BYTES) + described_class::GENERATED_HEADER_MARKER
      expect(described_class.generated?(padded)).to be false
    end

    it "is false for a file with no marker" do
      expect(described_class.generated?("name: x\n")).to be false
    end

    it "is false for a body that could not be read" do
      expect(described_class.generated?(nil)).to be false
    end
  end

  describe "#synced_body" do
    it "prefixes the header the way cimas writes it" do
      # A template that already ends with a newline: header, then body, byte
      # for byte. Six of the ten templates do not, hence the next example.
      body = File.read(config.template_path("gh-actions/master/rake.yml"))
      expect(config.synced_body("gh-actions/master/rake.yml"))
        .to eq("#{described_class::GENERATED_HEADER}\n#{body}")
    end

    it "adds the trailing newline cimas's line copy adds" do
      # copy_file uses File.foreach + out.puts, so a template with no final
      # newline gains one in the destination. A comparison that missed this
      # would call every such file diverged.
      allow(File).to receive(:read).and_return("Makefile body")
      expect(config.synced_body("gh-actions/model/Makefile"))
        .to end_with("Makefile body\n")
    end
  end

  describe "#findings" do
    let(:header) { "#{described_class::GENERATED_HEADER}\n" }

    it "calls a header-carrying unmapped file an orphan" do
      found = config.findings("relaton-model-gb", blobs("Gemfile" => "#{header}gem 'x'\n"))
      expect(found.map(&:state)).to eq([:orphan])
      expect(found.first.path).to eq("Gemfile")
    end

    it "calls a header-carrying mapped file mapped" do
      found = config.findings("relaton-models", blobs("Gemfile" => "#{header}gem 'x'\n"))
      expect(found.map(&:state)).to eq([:mapped])
    end

    it "calls a file with no header unmanaged, mapped or not" do
      found = config.findings(
        "relaton-models",
        blobs("Gemfile" => "gem 'x'\n", "README.adoc" => "= Title\n"),
      )
      expect(found.map(&:state)).to eq(%i[unmanaged unmanaged])
    end

    it "narrows to the requested target paths" do
      found = config.findings(
        "relaton-model-gb",
        blobs("Gemfile" => "#{header}gem 'x'\n", "Makefile" => "#{header}all:\n"),
        only_targets: ["Makefile"],
      )
      expect(found.map(&:path)).to eq(["Makefile"])
    end

    it "reports an orphan that matches the template it once came from" do
      found = config.findings(
        "relaton-model-gb",
        blobs("Gemfile" => config.synced_body("gh-actions/model/Gemfile")),
      )
      expect(found.first.match).to eq(:same)
      expect(found.first.template).to eq("gh-actions/model/Gemfile")
    end

    it "reports an orphan that has drifted from the template" do
      found = config.findings("relaton-model-gb", blobs("Gemfile" => "#{header}gem 'drifted'\n"))
      expect(found.first.match).to eq(:diverged)
    end

    it "reports no template for a path no repo maps" do
      found = config.findings("relaton-model-gb", blobs(".rubocop.yml" => "#{header}AllCops:\n"))
      expect(found.first.match).to be_nil
      expect(found.first.template).to be_nil
    end
  end

  describe "#orphans" do
    it "keeps only what cimas cleanup-orphan-files would delete" do
      header = "#{described_class::GENERATED_HEADER}\n"
      found = config.orphans(
        "relaton-models",
        blobs(
          "Gemfile" => "#{header}gem 'x'\n",        # mapped -> kept
          ".rubocop.yml" => "#{header}AllCops:\n",  # orphan -> deleted
          "README.adoc" => "= Title\n",             # no header -> never touched
        ),
      )
      expect(found.map(&:path)).to eq([".rubocop.yml"])
    end
  end
end
