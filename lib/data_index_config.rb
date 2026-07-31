require "yaml"

# Renders the per-repo GitHub Pages index `_config.yml` for each relaton-data-*
# repo from the single source of truth in `data-index/configs.yml`.
#
# The rendered file is committed into the data repo itself (it is repo-owned,
# like relaton-data-oasis/w3c/ids already are); the theme's `data-deploy.yml`
# workflow merges it over the theme's base `_config.yml` at build time.
class DataIndexConfig
  DEFAULT_CONFIG_PATH =
    File.expand_path("../data-index/configs.yml", __dir__).freeze

  attr_reader :defaults, :repos

  def self.load(path = DEFAULT_CONFIG_PATH)
    data = YAML.safe_load_file(path)
    new(data.fetch("defaults"), data.fetch("repos"))
  end

  def initialize(defaults, repos)
    @defaults = defaults
    @repos = repos
  end

  # Look up a single repo entry by its `repo` key.
  def entry(repo)
    repos.find { |e| e["repo"] == repo } or
      raise ArgumentError, "unknown repo: #{repo.inspect}"
  end

  # Render the `_config.yml` text for a repo name.
  def render_repo(repo)
    render(entry(repo))
  end

  # Render the `_config.yml` text for a raw entry hash (merged with defaults).
  def render(entry)
    display = entry.fetch("display")
    baseurl = format(defaults.fetch("baseurl_template"),
                     repo: entry.fetch("repo"), branch: entry.fetch("branch"))
    description = format(defaults.fetch("description_template"), display: display)

    lines = [
      "title: #{display} Index",
      "description: >-",
      "  #{description}",
      "paginate: #{defaults.fetch('paginate')}",
      "jekyll-index:",
      "  favicon: #{sq(defaults.fetch('favicon'))}",
      "  source: #{sq(entry.fetch('source'))}",
      "  baseurl: #{sq(baseurl)}",
      "  add_type_to_reference: true",
    ]

    pubid = pubid_class(entry)
    if pubid
      lines << "  pubid_class: #{sq(pubid)}"
      lines << "  pubid_require: #{sq(defaults.fetch('pubid_require'))}"
    end

    "#{lines.join("\n")}\n"
  end

  private

  # YAML single-quoted scalar with proper escaping ('' for a literal quote).
  def sq(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end

  # Normalise the pubid class: blank -> nil (flat index), and strip any leading
  # "::" because the theme plugin resolves the name with Object.const_get, which
  # rejects a leading namespace separator.
  def pubid_class(entry)
    value = entry["pubid_class"]
    return nil if value.nil? || value.strip.empty?

    value.strip.sub(/\A::/, "")
  end
end
