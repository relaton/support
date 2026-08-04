# Drift guard for the committed snapshot in data-index/generated/. Those files
# are the exact bytes a maintainer copies into each relaton-data-* repo as its
# `_config.yml`, so they must always equal the generator's current output. If
# configs.yml changes without regenerating (`bin/gen-data-index-config --out
# data-index/generated`), this fails and points at the stale file.
require "data_index_config"

RSpec.describe "data-index/generated snapshot" do
  config = DataIndexConfig.load
  generated_dir = File.expand_path("../data-index/generated", __dir__)

  config.repos.each do |entry|
    repo = entry.fetch("repo")

    it "generated/#{repo}_config.yml matches the generator output" do
      path = File.join(generated_dir, "#{repo}_config.yml")
      expect(File.exist?(path)).to be(true),
                                   "missing #{path} — run bin/gen-data-index-config --out data-index/generated"
      expect(File.read(path)).to eq(config.render_repo(repo)),
                                 "#{repo}_config.yml is stale — regenerate the snapshot"
    end
  end

  it "contains exactly one *_config.yml per target repo (no stale files)" do
    present = Dir.glob(File.join(generated_dir, "*_config.yml"))
                 .map { |p| File.basename(p, "_config.yml") }.sort
    expected = config.repos.map { |e| e["repo"] }.sort
    expect(present).to eq(expected)
  end
end
