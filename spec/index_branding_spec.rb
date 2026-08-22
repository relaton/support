# Guards the branding the shared data-deploy.yml resolves for `relaton index`.
#
# Branding used to live in each relaton-data-* repo's own deploy.yml `with:`
# block, which cimas.yml maps as a whole-file copy — so a `cimas sync` wiped it
# silently (the page just loses its favicon and description; nothing goes red).
# It now comes from data-index/configs.yml, the file that was already the source
# of truth for these values, and the caller template carries no `with:` at all.
#
# The load-bearing invariants here are the fallbacks: the workflow passes all
# three flags unconditionally, and Cimas syncs deploy.yml into one repo
# (relaton-data-ietf) that configs.yml deliberately does not cover.
require "English" # $CHILD_STATUS
require "shellwords"

require "data_index_config"

RSpec.describe "DataIndexConfig branding" do
  repo_root = File.expand_path("..", __dir__)
  cimas = YAML.safe_load_file(File.join(repo_root, "cimas-config/cimas.yml"))

  let(:config) { DataIndexConfig.load }

  describe ".flavor" do
    it "accepts the $GITHUB_REPOSITORY form" do
      expect(DataIndexConfig.flavor("relaton/relaton-data-itu-r")).to eq("itu-r")
    end

    it "ignores the owner, so a fork's PR build resolves the same branding" do
      expect(DataIndexConfig.flavor("someone/relaton-data-iso")).to eq("iso")
    end

    it "accepts a bare repo name or a bare flavor" do
      expect(DataIndexConfig.flavor("relaton-data-iso")).to eq("iso")
      expect(DataIndexConfig.flavor("iso")).to eq("iso")
    end
  end

  # #branding is now configs.yml's only branding consumer. It used to be
  # cross-checked here against the rendered Jekyll `_config.yml`, so that a
  # repo's Pages title could not differ from the one its generated config
  # claimed; that renderer is gone (support#58) and there is nothing left to
  # drift against.
  describe "#branding" do
    it "titles a repo from its display name, not its slug" do
      # The old shell derivation upcased the slug, giving "RFCS Index" and
      # "RFCSUBSERIES Index". configs.yml's `display` is the editorial name.
      expect(config.branding("relaton/relaton-data-rfcs")["title"]).to eq("RFC Index")
    end

    {
      "rfcs" => "RFC Index",
      "rfcsubseries" => "RFC Subseries Index",
      "ids" => "Internet-Drafts Index",
      "calconnect" => "CalConnect Index",
      "adobe" => "Adobe Index",
      "iso" => "ISO Index",
      "itu-r" => "ITU-R Index",
      "3gpp" => "3GPP Index",
    }.each do |repo, title|
      it "titles #{repo} #{title.inspect}" do
        expect(config.branding("relaton/relaton-data-#{repo}")["title"]).to eq(title)
      end
    end

    it "returns a repo's own favicon and description overrides" do
      branding = config.branding("relaton/relaton-data-w3c")

      expect(branding["favicon"]).to eq("https://www.w3.org/assets/logos/w3c/w3c-no-bars.svg")
      expect(branding["description"]).to start_with(
        "Welcome to the World Wide Web Consortium standards index site!",
      )
    end

    it "falls back to the shared favicon and the templated description" do
      branding = config.branding("relaton/relaton-data-iso")

      expect(branding["favicon"]).to eq("https://www.relaton.org/favicon.ico")
      expect(branding["description"]).to eq("Welcome to the ISO standards index site!")
    end

    it "prefers an explicit override over configs.yml" do
      branding = config.branding(
        "relaton/relaton-data-iso",
        title: "Custom", favicon: "custom.ico", description: "Custom desc",
      )

      expect(branding).to eq(
        "title" => "Custom", "favicon" => "custom.ico", "description" => "Custom desc",
      )
    end

    it "treats an explicit blank override as unset" do
      # Load-bearing: the workflow passes --title/--favicon/--description
      # unconditionally, so an unset caller input arrives as "". If "" won, every
      # repo whose caller omits an input would lose its configs.yml branding —
      # exactly the bug this change closes.
      blank = config.branding("relaton/relaton-data-iso", title: "", favicon: " ",
                                                          description: nil)

      expect(blank).to eq(config.branding("relaton/relaton-data-iso"))
    end

    it "falls back to the derived title and no branding for a repo configs.yml omits" do
      # relaton-data-ietf gets deploy.yml from Cimas but publishes no document
      # index, so it has no configs.yml row (see cimas_data_pages_spec.rb).
      # Its result must match what the retired shell derivation produced.
      expect(config.branding("relaton/relaton-data-ietf"))
        .to eq("title" => "IETF Index", "favicon" => "", "description" => "")
    end

    it "does not raise for an unknown repo, unlike #entry" do
      # #entry raises ArgumentError by design; branding must not, or a single
      # missing configs.yml row would fail every Pages build in that repo.
      expect { config.branding("relaton/relaton-data-nope") }.not_to raise_error
      expect { config.entry("nope") }.to raise_error(ArgumentError)
    end

    it "resolves for every repo Cimas syncs deploy.yml into" do
      # The blast radius: data-deploy.yml is pinned @main by all of them, so a
      # resolver that raised for one repo would break that repo's deploys the
      # moment this lands.
      repositories = cimas.fetch("repositories")
      synced = cimas.fetch("groups").fetch("data").select do |name|
        (repositories.fetch(name, {})["files"] || {}).key?(".github/workflows/deploy.yml")
      end

      expect(synced).not_to be_empty
      synced.each do |name|
        branding = config.branding("relaton/#{name}")
        expect(branding.values).to all(be_a(String)),
                                   "#{name} resolved a non-String: #{branding.inspect}"
        expect(branding["title"]).not_to be_empty
      end
    end
  end

  # The unit examples above all bypass the executable the workflow actually runs.
  # Without these, renaming a method on GithubOutput or DataIndexConfig would
  # leave the whole suite green and break the resolve step in all 30 repos.
  describe "bin/index-branding" do
    bin = File.join(repo_root, "bin/index-branding")

    # Ruby's $GITHUB_OUTPUT format: `name<<DELIM\n...\nDELIM\n` blocks.
    parse = lambda do |text|
      text.scan(/^(\w[\w-]*)<<(\S+)\n(.*?)\n\2$/m).to_h { |name, _, value| [name, value] }
    end

    it "prints the resolved branding to stdout in $GITHUB_OUTPUT form" do
      out = `#{bin.shellescape} relaton/relaton-data-w3c 2>/dev/null`

      expect($CHILD_STATUS).to be_success
      expect(parse.call(out)).to eq(
        config.branding("relaton/relaton-data-w3c"),
      )
    end

    it "resolves a repo configs.yml does not cover" do
      out = `#{bin.shellescape} relaton/relaton-data-ietf 2>/dev/null`

      expect($CHILD_STATUS).to be_success
      expect(parse.call(out))
        .to eq("title" => "IETF Index", "favicon" => "", "description" => "")
    end

    it "applies the flags the workflow always passes, blanks included" do
      # The exact call shape of the Resolve branding step: all three flags, with
      # an unset caller input arriving as "".
      out = `#{bin.shellescape} relaton/relaton-data-iso --title "" --favicon "" \
             --description "Custom" 2>/dev/null`

      parsed = parse.call(out)
      expect(parsed.fetch("title")).to eq("ISO Index")
      expect(parsed.fetch("favicon")).to eq("https://www.relaton.org/favicon.ico")
      expect(parsed.fetch("description")).to eq("Custom")
    end

    it "keeps diagnostics off stdout, which is redirected into $GITHUB_OUTPUT" do
      out = `#{bin.shellescape} relaton/relaton-data-iso 2>/dev/null`

      # Every line belongs to a heredoc block; nothing stray can define an output.
      expect(out.lines.first).to match(/\Atitle<<\S+\n\z/)
      expect(out).to end_with("\n")
    end

    it "exits non-zero without exactly one repo argument" do
      # bash -e fails the step on this, rather than writing a partial block.
      expect(`#{bin.shellescape} 2>/dev/null`).to be_empty
      expect($CHILD_STATUS).not_to be_success
    end
  end
end
