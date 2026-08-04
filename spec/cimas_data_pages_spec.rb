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
end
