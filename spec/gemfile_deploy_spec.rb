# Structural guard for the deploy-time bundle Cimas syncs into every
# relaton-data-* repo (cimas-config/gh-actions/data/Gemfile.deploy).
#
# The Pages build (`.github/workflows/data-deploy.yml`) resolves against this
# file, so it must layer the Jekyll toolchain ON TOP of the repo's own Gemfile
# (relaton + the flavor's pubid) via `eval_gemfile`. If that layering regresses,
# `bundle exec jekyll build` loses either Jekyll or pubid and structured DocIDs
# fall back to a compact string.
RSpec.describe "cimas-config/gh-actions/data/Gemfile.deploy" do
  repo_root = File.expand_path("..", __dir__)
  gemfile_deploy =
    File.read(File.join(repo_root, "cimas-config/gh-actions/data/Gemfile.deploy"))

  it "layers on the repo's own Gemfile via eval_gemfile" do
    # Pulls in the flavor's relaton + pubid pins so one shared Gemfile.deploy
    # works for every flavor without duplicating per-repo pins.
    expect(gemfile_deploy).to match(/eval_gemfile\b.*Gemfile/)
  end

  it "declares the Jekyll toolchain the build needs" do
    %w[jekyll csv jekyll-paginate kramdown-parser-gfm webrick].each do |name|
      expect(gemfile_deploy).to match(/gem\s+["']#{Regexp.escape(name)}["']/),
                                "expected Gemfile.deploy to declare gem #{name.inspect}"
    end
  end

  it "does not declare its own primary source (inherits it from the eval'd Gemfile)" do
    # A second `source "https://rubygems.org"` triggers bundler's multi-source
    # warning; the eval'd repo Gemfile already sets it.
    expect(gemfile_deploy).not_to match(/^\s*source\s+["']https:\/\/rubygems\.org["']/)
  end
end
