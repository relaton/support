# The audit's record of every orphan a person has already looked at.
#
# `cimas.yml` says what Cimas syncs; this file says what a cleanup wave would
# find in the destination repos and what was decided about it. The two are
# complements. `relaton-data-itu` needs only a cimas.yml marker, because its
# crawler.yml lost the Cimas header and can never be deleted; `relaton-render`
# needs only an allowlist row, because nothing was ever un-mapped there — the
# header on its .rubocop.yml comes from a config older than this repo.
require "cimas_config"
require "orphan_allowlist"

RSpec.describe OrphanAllowlist do
  let(:allowlist) { described_class.load }
  let(:config) { CimasConfig.load }

  def finding(repo, path)
    CimasConfig::Finding.new(repo: repo, path: path, state: :orphan)
  end

  describe "the shipped file" do
    it "gives every row a repo cimas.yml knows" do
      unknown = allowlist.entries.map { |e| e.fetch("repo") }.uniq
                         .reject { |name| config.names.include?(name) }
      expect(unknown).to be_empty,
                         "these rows name a repo cimas.yml does not: #{unknown.join(', ')}"
    end

    it "gives every row a path that repo does not map" do
      # A path the mapping covers is not an orphan, so the row is stale: Cimas
      # regenerates the file and no wave can delete it.
      stale = allowlist.entries.select do |entry|
        config.files(entry.fetch("repo")).key?(entry.fetch("path"))
      end
      expect(stale).to be_empty,
                       "cimas.yml now maps these, so the rows are dead: " \
                       "#{stale.map { |e| "#{e['repo']} #{e['path']}" }.join(', ')}"
    end

    it "gives every row a date, an issue and a reason" do
      incomplete = allowlist.entries.reject do |entry|
        entry["since"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) &&
          entry["issue"].to_s.match?(%r{\A[\w.-]+/[\w.-]+\#\d+\z}) &&
          !entry["reason"].to_s.strip.empty?
      end
      expect(incomplete).to be_empty,
                            "these rows are missing a since, issue or reason: " \
                            "#{incomplete.map { |e| "#{e['repo']} #{e['path']}" }.join(', ')}"
    end

    it "gives every row a known disposition" do
      unknown = allowlist.entries.map { |e| e["disposition"] }.uniq -
                described_class::DISPOSITIONS
      expect(unknown).to be_empty,
                         "unknown disposition(s) #{unknown.inspect}; " \
                         "use one of #{described_class::DISPOSITIONS.join(', ')}"
    end

    it "names the hand-off that will retire every `keep` row" do
      # A `keep` row is permanent only while the destination file still carries
      # the Cimas header. Dropping that header is the real fix, and it happens
      # in the destination repo, so each row has to say where that work is
      # written down.
      missing = allowlist.entries.select do |entry|
        entry["disposition"] == "keep" && entry["handoff"].to_s.strip.empty?
      end
      expect(missing).to be_empty,
                         "these `keep` rows name no hand-off: " \
                         "#{missing.map { |e| "#{e['repo']} #{e['path']}" }.join(', ')}"
    end
  end

  describe "#covers?" do
    it "is true for a listed repo and path" do
      first = allowlist.entries.first
      expect(allowlist.covers?(first.fetch("repo"), first.fetch("path"))).to be true
    end

    it "is false for a path that is not listed" do
      expect(allowlist.covers?("relaton-render", "Gemfile")).to be false
    end
  end

  describe "#stale" do
    let(:allowlist) do
      described_class.new(
        [
          { "repo" => "relaton-render", "path" => ".hound.yml", "disposition" => "keep" },
          { "repo" => "relaton-core", "path" => ".rubocop.yml", "disposition" => "keep" },
        ],
      )
    end

    it "names a row whose file the audit no longer found" do
      found = [finding("relaton-render", ".hound.yml")]
      expect(allowlist.stale(found, scanned: %w[relaton-render relaton-core]))
        .to eq([{ "repo" => "relaton-core", "path" => ".rubocop.yml",
                  "disposition" => "keep" }])
    end

    it "keeps quiet about a repo this run did not scan" do
      # `bin/cimas-orphan-audit relaton-render` must not call every other
      # repo's row stale.
      found = [finding("relaton-render", ".hound.yml")]
      expect(allowlist.stale(found, scanned: %w[relaton-render])).to be_empty
    end

    it "keeps quiet about a path this run did not look for" do
      # The same rule for --only-target: a run scoped to one path says nothing
      # about the rows for every other path.
      found = [finding("relaton-render", ".hound.yml")]
      expect(allowlist.stale(found, scanned: %w[relaton-render relaton-core],
                                    paths: [".hound.yml"])).to be_empty
    end
  end
end
