# Guards the two-track Pages rollout against the "silent 404" class the cimas.yml
# `# data` comment warns about: the per-repo config (data-index/configs.yml) and the
# Cimas plumbing (cimas-config/cimas.yml) must agree on every target relaton-data-*
# repo. If a repo's `branch:` drifts between the two files, or its deploy.yml /
# Gemfile.deploy mapping goes missing, the reusable data-deploy.yml silently skips
# the Pages publish (it only deploys from the repo's real default branch) and the
# site 404s with nothing red in CI. This spec makes that drift a test failure.
require "data_index_config"

RSpec.describe "configs.yml <-> cimas.yml consistency" do
  repo_root = File.expand_path("..", __dir__)

  configs = DataIndexConfig.load
  cimas = YAML.safe_load_file(
    File.join(repo_root, "cimas-config/cimas.yml"),
  )
  repositories = cimas.fetch("repositories")
  data_group = cimas.fetch("groups").fetch("data")

  # Local (not a constant) so it stays scoped to this example group rather than
  # leaking to top-level Object; the nested `it` blocks close over it.
  deploy_mapping = {
    ".github/workflows/deploy.yml" => "gh-actions/data/deploy.yml",
    "Gemfile.deploy" => "gh-actions/data/Gemfile.deploy",
  }.freeze

  configs.repos.each do |entry|
    repo = entry.fetch("repo")
    cimas_key = "relaton-data-#{repo}"

    context "relaton-data-#{repo}" do
      it "has a repositories: entry in cimas.yml" do
        expect(repositories).to have_key(cimas_key),
                                "configs.yml lists #{repo.inspect} but cimas.yml has no " \
                                "#{cimas_key.inspect} entry to sync deploy.yml into"
      end

      it "is listed in the cimas.yml `data` group" do
        expect(data_group).to include(cimas_key)
      end

      it "targets the same branch cimas.yml pushes to" do
        # Both drive the default-branch publish gate: configs.yml's branch builds
        # the raw baseurl; cimas.yml's branch is where deploy.yml lands. A mismatch
        # publishes from one branch while the site is served from another -> 404.
        expect(repositories.fetch(cimas_key).fetch("branch"))
          .to eq(entry.fetch("branch"))
      end

      it "maps both deploy.yml and Gemfile.deploy from the data templates" do
        files = repositories.fetch(cimas_key).fetch("files")
        deploy_mapping.each do |dest, src|
          expect(files[dest]).to eq(src),
                                 "expected #{cimas_key} to map #{dest} <- #{src}"
        end
      end
    end
  end

  it "every relaton-data-* repo in the `data` group with a deploy.yml is covered by configs.yml" do
    # The reverse direction: a data repo that Cimas pushes deploy.yml into but that
    # has no configs.yml row would deploy the theme with no per-repo _config.yml.
    # Excludes are the deliberate non-index repos (see data-pages-rollout hand-off).
    known = configs.repos.map { |e| "relaton-data-#{e['repo']}" }
    # ietf gets deploy.yml but is deliberately not a Pages index (no document
    # index published); every other data-group repo is covered by configs.yml,
    # including the already-live ids/oasis/w3c now folded in.
    excluded = %w[relaton-data-ietf]
    deploys_pages =
      data_group.select do |name|
        files = repositories.fetch(name, {}).fetch("files", nil) || {}
        files.key?(".github/workflows/deploy.yml")
      end
    uncovered = deploys_pages - known - excluded
    expect(uncovered).to be_empty,
                         "these data repos get deploy.yml but have no configs.yml row: " \
                         "#{uncovered.join(', ')}"
  end

  # The failure mode that made this whole change necessary is entirely silent: a
  # per-repo value in a Cimas-synced template is copied verbatim into 29 repos,
  # and a per-repo value hand-added to a *synced destination* is reverted on the
  # next sync with nothing red in CI. These two guards make either a test
  # failure, for every template cimas.yml syncs — not just deploy.yml.
  describe "no Cimas-synced template can carry a per-repo value" do
    # Every source template any repositories: entry maps, YAML ones only.
    templates = repositories.values.compact
                            .flat_map { |r| (r["files"] || {}).values }
                            .uniq.select { |src| %w[.yml .yaml].include?(File.extname(src)) }
                            .sort

    # Walk a parsed document and yield every String it contains. Deliberately
    # parsed rather than raw text: gh-actions/data/deploy.yml legitimately names
    # relaton-data-iana in a comment (as evidence for its cron window), and a
    # File.read scan would flag it.
    scalars = lambda do |node, &blk|
      case node
      when Hash then node.each { |k, v| scalars.call(k, &blk); scalars.call(v, &blk) }
      when Array then node.each { |v| scalars.call(v, &blk) }
      when String then blk.call(node)
      end
    end

    # The repo slug, plus the rendered page title. Deliberately NOT the bare
    # `display` value: those are short acronyms (RFC, ISO, IEC, CIE, XSF), and
    # substring-matching them would fail an unrelated template the day one names
    # `ISO 8601` or `RFC 3339` in a step. `<display> Index` is the shape a leaked
    # per-repo title actually takes.
    per_repo_tokens = configs.repos.flat_map do |e|
      ["relaton-data-#{e.fetch('repo')}", "#{e.fetch('display')} Index"]
    end

    templates.each do |src|
      it "#{src} names no single repo" do
        doc = YAML.safe_load_file(File.join(repo_root, "cimas-config", src))
        offenders = []
        scalars.call(doc) do |string|
          per_repo_tokens.each { |t| offenders << [t, string] if string.include?(t) }
        end

        expect(offenders).to be_empty,
                             "#{src} is copied byte-for-byte into every mapped repo, but " \
                             "contains per-repo value(s): #{offenders.inspect}. Per-repo " \
                             "values belong in data-index/configs.yml."
      end

      it "#{src} passes only run-time expressions as workflow inputs" do
        # A literal `with:` value is per-repo configuration. An expression
        # (crawler.yml's `${{ github.event.inputs.args }}`, release.yml's
        # `${{ github.event.inputs.next_version }}`) evaluates per run and is
        # therefore repo-agnostic, so it survives a sync intact.
        # `|| {}` twice: a comment-only or empty template parses to nil.
        doc = YAML.safe_load_file(File.join(repo_root, "cimas-config", src)) || {}
        literals = (doc["jobs"] || {}).flat_map do |name, job|
          next [] unless job.is_a?(Hash) && job.key?("uses")

          (job["with"] || {}).reject { |_, v| v.to_s.match?(/\A\$\{\{.*\}\}\z/) }
                             .map { |k, v| "#{name}.with.#{k}=#{v.inspect}" }
        end

        expect(literals).to be_empty,
                            "#{src} passes literal input(s) #{literals.join(', ')} that a " \
                            "`cimas sync` would copy into every mapped repo"
      end
    end
  end
end
