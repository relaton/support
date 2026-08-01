# Guards the reusable Pages workflow so it resolves gems against Gemfile.deploy
# (the jekyll + pubid bundle) rather than the data repo's own crawler Gemfile.
RSpec.describe ".github/workflows/data-deploy.yml" do
  repo_root = File.expand_path("..", __dir__)
  workflow = YAML.safe_load_file(File.join(repo_root, ".github/workflows/data-deploy.yml"))
  build_job = workflow.fetch("jobs").fetch("build_index_page")

  it "points BUNDLE_GEMFILE at Gemfile.deploy for the build job" do
    # setup-ruby's bundler-cache install AND `bundle exec jekyll build` both
    # honor this env, so the whole job uses the layered deploy bundle.
    bundle_gemfile = build_job.fetch("env").fetch("BUNDLE_GEMFILE")
    expect(bundle_gemfile).to end_with("Gemfile.deploy")
  end

  it "still builds with `bundle exec jekyll build`" do
    run_steps = build_job.fetch("steps").filter_map { |s| s["run"] }
    expect(run_steps).to include(a_string_matching(/bundle exec jekyll build/))
  end
end
