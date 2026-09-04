# Offline unit tests for CimasConfig, the reader behind bin/cimas-orphan-audit.
# The network half (listing and fetching each destination repo) lives only in
# the executable; the orphan decision itself is pure logic and is pinned here,
# because that decision is what deletes files.
require "cimas_config"

RSpec.describe CimasConfig do
  let(:config) { described_class.load }

  # A minimal stand-in for a destination repo: the file bodies bin/ fetches,
  # keyed by their path in that repo.
  def blobs(pairs)
    pairs
  end

  describe ".load" do
    it "reads every repositories: entry of the shipped cimas.yml" do
      expect(config.names.size).to eq(98)
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
    it "names every repo that no group lists" do
      # `cimas -g <group>` never reaches these, so a wave scoped by group has a
      # different blast radius from `-g all`. The audit warns about it. The
      # list is asserted whole so a new ungrouped repo is a visible edit; none
      # of these five maps a file today.
      expect(config.ungrouped).to eq(
        %w[relaton-core ieee-idams loc_marc loc_mods rawdata-bipm-metrologia],
      )
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
