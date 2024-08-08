require 'set'
require 'uri'
require 'net/http'
require 'json'
require 'date'
require 'elasticsearch'
require 'nokogiri'

SEARCH_URL = (ENV["SEARCH_ORIGIN"] || 'https://search.modelshub.johnsnowlabs.com') + '/'
ELASTICSEARCH_INDEX_NAME = ENV["ELASTICSEARCH_INDEX_NAME"] || 'models'

ORIGIN = ENV["ORIGIN"] || ""

OUTDATED_EDITIONS = ['Spark NLP 2.0', 'Spark NLP 2.1', 'Healthcare NLP 2.0']
SPARK_NLP_ORIGIN = "https://sparknlp.org"
JOHNSNOWLABS_ORIGIN = "https://nlp.johnsnowlabs.com"
OPEN_SOURCE_MODEL_TO_NOT_REDIRECT = [ "/2020/01/22/glove_100d.html",
"/2021/11/22/lemma_antbnc_en.html",
"/2020/07/14/stopwords_hi.html",
"/2020/12/05/arabic_w2v_cc_300d_ar.html",
"/2022/05/04/bert_ner_ANER_ar_3_0.html",
"/2022/03/07/stopwords_iso_vi_3_0.html",
"/2021/01/03/translate_mul_en_xx.html",
"/2020/04/17/tfhub_use.html",
"/2022/04/01/spellcheck_dl_en_2_4.html",
"/2020/05/03/lemma_nl.html",
"/2021/11/04/bert_sequence_classifier_question_statement_en.html",
"/2021/01/02/sentence_detector_dl_en.html"]

$remote_editions = Set.new

class Version < Array
  def initialize name
    m = /(\d+\.\d+)\z/.match(name)
    super(m ? m[1].split('.').map(&:to_i) : [])
  end

  def < x
    (self <=> x) < 0
  end

  def <= x
    (self <=> x) <= 0
  end
end

def edition_name(old_product)
  old_to_new_product_name = {
    'Spark NLP for Legal'=> 'Legal NLP',
    'Spark NLP for Finance'=> 'Finance NLP',
    'Spark OCR'=> 'Visual NLP',
    'Spark NLP for Healthcare'=> 'Healthcare NLP',
  }
  old_to_new_product_name.each do |key, value|
    if old_product.include? key
      return old_product.sub(key, value)
    end
  end
  old_product
end

def compatible_editions(editions, model_editions, edition)
  return edition if edition.to_s.empty?

  return edition if OUTDATED_EDITIONS.include? edition

  def to_product_name(edition)
    m = /^(.*?) \d+\.\d+$/.match(edition)
    return m ? m[1] : nil
  end

  product_name = to_product_name(edition)
  if product_name
    selection_lambda = lambda {|v| to_product_name(v) == product_name && !OUTDATED_EDITIONS.include?(v)}
  else
    selection_lambda = lambda {|_| false }
  end

  editions = editions.select &selection_lambda
  model_editions = model_editions.select &selection_lambda

  curr_index = model_editions.index(edition)
  return edition if curr_index.nil?

  min = edition
  max = model_editions[curr_index + 1].nil? ? nil : model_editions[curr_index + 1]
  editions.select do |v|
    if min && max
      (Version.new(min) <= Version.new(v)) && (Version.new(v) < Version.new(max))
    elsif max
      Version.new(v) < Version.new(max)
    else
      Version.new(min) <= Version.new(v)
    end
  end
end

def editions_changed?(edition)
  if $remote_editions.empty?
    puts "Retrieving remote editions...."
    uri = URI(SEARCH_URL)
    res = Net::HTTP.get_response(uri)
    if res.is_a?(Net::HTTPSuccess)
      data = JSON.parse(res.body)
      editions = data['meta']['aggregations']['editions']
      $remote_editions = editions.to_set
    end
  end
  local_editions = Set.new
  local_editions << edition
  return !(local_editions - OUTDATED_EDITIONS).to_set.subset?($remote_editions)
end

def to_product_name(edition_short)
  m = /^(.*?)\s\d+\.\d+$/.match(edition_short)
  m ? m[1] : nil
end

class Extractor
  def initialize(content)
    @content = content
  end

  def download_link
    m = /\[Download\]\((.*?)\)/.match(@content)
    m ? m[1] : nil
  end

  def doc_type
    m = /\|Type:\|(.*?)\|/.match(@content)
    if m
      return m[1] == 'pipeline' ? 'pipeline': 'model'
    end
    nil
  end

  def print_error(message)
    if ENV["DEBUG"]
      print(message + "\n")
    end
  end

  def origin
    m = /\|\s*License:\s*\|\s*Licensed\s*\|/m.match(@content)
    m ? JOHNSNOWLABS_ORIGIN : SPARK_NLP_ORIGIN
  end

  def predicted_entities
    m = /## Predicted Entities(.*?)(##|{:\.btn-box\})/m.match(@content)
    if m
      buf = m[1].strip
      strategies = ['newline_separated', 'comma_separated']
      while strategies.length > 0 do
        case strategies.pop
        when 'comma_separated'
          items = self.comma_separated_predicted_entities(buf)
        when 'newline_separated'
          items = self.newline_separated_predicted_entities(buf)
        end
        return items if items
      end
    end
    nil
  end

  def benchmarking_results(post_url)
    if @content.include? '## Benchmarking'
      m = /## Benchmarking(\r\n|\r|\n)+```bash(.*?)```/m.match(@content)
      if m

        buf = m[2].strip
        lines = buf.split("\n")
        col_index_to_header_mapping = {}
        return_data = []
        lines.each_with_index do |line, index|
          if index == 0
              # This is a header row
              headers = line.split
              if headers.include?('|')
                print_error("Failed to parse the Benchmarking section (invalid syntax) #{post_url}")
                return nil
              end
              unless headers.include?('label')
                print_error("Failed to parse the Benchmarking section (the label header is missing) #{post_url}")
                return nil
              end
              headers.each_with_index do |header, i|
                  if header == 'label'
                      header = 'name'
                  end
                  col_index_to_header_mapping[i] = header
              end
          else
              row_data = {}
              values = line.split
              if values.length != col_index_to_header_mapping.keys.count
                print_error("Failed to parse the Benchmarking section (different column and cell count) #{post_url}")
                return nil
              end
              values.each_with_index do |value, j|
                if value.include?("prec:") or value.include?("rec:") or value.include?("f1:")
                  print_error("Failed to parse the Benchmarking section (cells contains columns) #{post_url}")
                  return nil
                end
                row_data[col_index_to_header_mapping[j]]=value
              end
              unless row_data.empty?
                  return_data << row_data
              end
          end
        end
        return return_data
      else
        print_error("Failed to parse the Benchmarking section (invalid section) #{post_url}")
      end
    end
    nil
  end

  def references_results(post_url)
    if @content.include? '## References'
      m = /^## References[^#]+([\W\w]*?)($)/m.match(@content)
      if m
        references_section = m[0]
        url_scans = references_section.scan(URI.regexp)
        return url_scans.map do |url_parts|
          if not url_parts.one?
            url_parts.each_with_index.map do |part, index|
              if index == 0
                part = part + "://"
              end
              part
            end.join.delete_suffix('.').delete_suffix(')')
          end
        end.compact.uniq
      end
    end
    nil
  end


  private

  def comma_separated_predicted_entities(buf)
    has_comma = buf.include?(',')
    has_apostrophe = buf.include?('`')
    buf = buf.gsub("\n", ' ')
    return nil unless has_comma || (has_apostrophe && buf.match?(/\A\S+\z/))
    buf.scan(/`[^`]+`/).map { |v| v.gsub(/["`]/, '') }.select { |v| !v.empty? && !v.include?(',') && !v.include?('|') }
  end

  def newline_separated_predicted_entities(buf)
    return nil unless buf.include? "\n"
    return nil unless buf.strip.start_with? '-'
    buf.split("\n").collect { |v| v.gsub(/^-\s?/, '').gsub('`', '').strip }.select { |v| !v.empty? }
  end
end

class BulkIndexer
  def initialize(client)
    @client = client
    @buffer = []
  end

  def index(id, data)
    @buffer << { update: { _id: id, data: {doc: data, doc_as_upsert: true}} }
    self.execute if @buffer.length >= 100
  end

  def execute
    return nil unless @client
    return nil if @buffer.empty?
    puts "Indexing #{@buffer.length} models..."
    @client.bulk(index: ELASTICSEARCH_INDEX_NAME, body: @buffer)
    @buffer.clear
  end
end

editions = Set.new
# Add the editions that are absent in the existing models yet
editions << 'Visual NLP 4.2'
uniq_to_models_mapping = {}
name_language_editions_sparkversion_to_models_mapping = {}
models_json = {}
models_benchmarking_json = {}
models_references_json = {}

all_posts_id = []

all_deleted_posts = []

def is_latest?(group, model)
  models = group[model[:uniq_key]]
  Date.parse(model[:date]) == models.map { |m| Date.parse(m[:date])}.max
end


Jekyll::Hooks.register :posts, :pre_render do |post|
  extractor = Extractor.new(post.content)
  doc_type = extractor.doc_type
  if doc_type.nil?
    doc_type = post.data['tags'].include?('pipeline') ? 'pipeline' : 'model'
  end
  post.data['edition'] = edition_name(post.data['edition'])

  post.data["origin"] = extractor.origin

  models_json[post.url] = {
    title: post.data['title'],
    date: post.data['date'].strftime('%B %d, %Y'),
    name: post.data['name'],
    class: post.data['class'] || "",
    language: post.data['language'],
    task: post.data['task'],
    edition: post.data['edition'],
    categories: post.data['categories'],
    url: post.url,
    tags: post.data['tags'],
    download_link: extractor.download_link,
    predicted_entities: extractor.predicted_entities || [],
    type: doc_type,
    annotator: post.data['annotator'] || "",
    deprecated: !!post.data['deprecated']
  }

  benchmarking_info = extractor.benchmarking_results(post.url)
  if benchmarking_info
    models_benchmarking_json[post.url] = benchmarking_info
  end

  references = extractor.references_results(post.url)
  if references
    models_references_json[post.url] = references
  end
end

Jekyll::Hooks.register :posts, :post_render do |post|
  m = !post.data['edition'].nil? && /(.*)\.(\d+)\z/.match(post.data['edition'])
  edition_short = m.is_a?(MatchData) ? m[1] : ''

  body = Nokogiri::HTML(post.content)
  body.search('h2, pre, table, .btn-box, .tabs-box, .highlight').remove
  body = body.text.gsub(/\s+/, ' ').strip

  language = post.data['language']
  languages = [language]
  if language == 'xx'
    languages = post.data['tags'].select do |v|
      v.length <= 3 and /^[a-z]+$/.match?(v) and v != 'ner' and v != 'use'
    end
  end

  supported = !!post.data['supported']
  deprecated = !!post.data['deprecated']
  recommended = !!post.data['recommended']
  key = "#{post.data['name']}_#{post.data['language']}_#{post.data['edition']}_#{post.data["spark_version"]}"

  model = {
    id: post.url,
    name: post.data['name'],
    title: post.data['title'],
    tags_glued: post.data['tags'].join(' '),
    tags: post.data['tags'],
    task: post.data['task'],
    language: language,
    languages: languages,
    edition: post.data['edition'],
    edition_short: edition_short,
    date: post.data['date'].strftime('%F'),
    supported: supported && !deprecated,
    deprecated: deprecated,
    body: body,
    url: post.url,
    recommended: recommended,
    annotator: post.data['annotator'],
    uniq_key: key,
    origin: post.data["origin"],
  }
  unless post.data["deploy"].nil?
    model[:marketplace] = {
      databricks: post.data["deploy"]["databricks_link"],
      sagemaker: post.data["deploy"]["sagemaker_link"],
      snowflake: post.data["deploy"]["snowflake_link"]
    }
  end

  uniq = "#{post.data['name']}_#{post.data['language']}"
  uniq_to_models_mapping[uniq] = [] unless uniq_to_models_mapping.has_key? uniq
  uniq_to_models_mapping[uniq] << model
  unless edition_short.empty?
    editions.add(edition_short)
    if not ENV['FULL_BUILD'] and editions_changed?(edition_short)
      print("Please retry again with full build. New edition #{edition_short} encountered.")
      # Write to $GITHUB_OUPUT for CI/CD
      if ENV["GITHUB_OUTPUT"]
        open(ENV["GITHUB_OUTPUT"], 'a') do |f|
          f << "require_full_build=true"
        end
      end
      # exit raises a SystemExit exception with exit code 11
      exit(11)
    end
  end


  name_language_editions_sparkversion_to_models_mapping[key] = [] unless name_language_editions_sparkversion_to_models_mapping.has_key? key
  name_language_editions_sparkversion_to_models_mapping[key] << model
  all_posts_id << model[:id]
  # Change redirects for open source model pages
  if post.data["origin"] == SPARK_NLP_ORIGIN and not OPEN_SOURCE_MODEL_TO_NOT_REDIRECT.include?(post.url)
    redirect_to= SPARK_NLP_ORIGIN + post.url
    post.content = post.output= %Q(<!DOCTYPE html>
<html lang="en-US">
  <meta charset="utf-8">
  <title>Redirecting&hellip;</title>
  <link rel="canonical" href="#{redirect_to}">
  <script>location="#{redirect_to}"</script>
  <h1>Redirecting&hellip;</h1>
  <a href="#{redirect_to}">Click here if you are not redirected.</a>
</html>
    )
  end
end

client = nil
unless ENV['ELASTICSEARCH_URL'].to_s.empty?

  if ORIGIN.empty?
    print("Cannot proceed further. Please set ENV variable ORIGIN")
    exit(1) 
  end

  puts "Connecting to Elasticsearch..."
  client = Elasticsearch::Client.new(
    url: ENV['ELASTICSEARCH_URL'],
    transport_options: {
      headers: {
        'Authorization': "Bearer #{ENV['ELASTICSEARCH_ACCESS_TOKEN']}"
      },
      request: {
        open_timeout: 60,
        timeout: 60,
      },
    },
  )
  exists =  client.indices.exists index: ELASTICSEARCH_INDEX_NAME
  puts "Index already exists: #{exists}"
  unless exists
    client.indices.create index: ELASTICSEARCH_INDEX_NAME, body: {
       "mappings": {
        "properties": {
            "body": {
                "type": "text",
                "analyzer": "english"
            },
            "date": {
                "type": "date",
                "format": "yyyy-MM-dd"
            },
            "edition": {
                "type": "keyword"
            },
            "edition_short": {
                "type": "keyword"
            },
            "language": {
                "type": "keyword"
            },
            "languages": {
                "type": "keyword"
            },
            "supported": {
                "type": "boolean"
            },
            "deprecated": {
                "type": "boolean"
            },
            "tags": {
                "type": "keyword"
            },
            "tags_glued": {
                "type": "text"
            },
            "predicted_entities": {
              "type": "keyword"
            },
            "type": {
              "type": "keyword"
            },
            "task": {
                "type": "keyword"
            },
            "name": {
                "type": "text",
                "analyzer": "simple"
            },
            "title": {
                "type": "text",
                "analyzer": "english"
            },
            "url": {
              "type": "keyword"
            },
            "download_link": {
              "type": "keyword"
            },
            "views": {
              "type": "integer"
            },
            "downloads": {
              "type": "integer"
            },
            "recommended": {
              "type": "boolean"
            },
            "annotator": {
              "type": "keyword"
            },
            "origin": {
              "type": "keyword"
            },
            "marketplace": {
              "properties": {
                "databricks": "keyword",
                "snowflake": "keyword",
                "sagemaker": "keyword"
              }
            }
        }
      }
    }
  end
end

Jekyll::Hooks.register :site, :post_render do |site|
  is_incremental = site.config['incremental']
  bulk_indexer = BulkIndexer.new(client)

  uniq_to_models_mapping.each do |uniq, items|
    items.sort_by! { |v| v[:edition_short] }
    model_editions = items.map { |v| v[:edition_short] }.uniq
    items.each do |model|
      next_edition_short = compatible_editions(
        editions,
        model_editions,
        model[:edition_short]
      )

      product_name = to_product_name(model[:edition_short])
      model[:edition_short] = next_edition_short
      if product_name
        case model[:edition_short]
        when Array
          model[:edition_short] << product_name
        when String
          model[:edition_short] = [model[:edition_short], product_name]
        end
      end

      models_json[model[:url]][:compatible_editions] = next_edition_short.empty? ? [] : Array(next_edition_short)
      # Add model_type to search models
      model[:type] = models_json[model[:url]][:type]
      # Add predicted entities to search models
      model[:predicted_entities] = models_json[model[:url]][:predicted_entities]
      # Add download_link to search models
      model[:download_link] = models_json[model[:url]][:download_link]

      if client
        if is_latest?(name_language_editions_sparkversion_to_models_mapping, model)
          id = model.delete(:id)
          model.delete(:uniq_key)
          bulk_indexer.index(id, model)
        end
      end
    end
  end
  bulk_indexer.execute

  if client and (not is_incremental or ENV["FULL_BUILD"])
    # For full build, remove all documents not in site.posts and belonging to the origin
    client.delete_by_query index: ELASTICSEARCH_INDEX_NAME, body: {query: {bool: { must: { match: {origin: ORIGIN }}, must_not: {ids: {values: all_posts_id}}}}}
  end
end

Jekyll::Hooks.register :site, :post_write do |site|
  is_incremental = site.config['incremental']
  backup_filename = File.join(site.config['source'], 'backup-models.json')
  backup_benchmarking_filename = File.join(site.config['source'], 'backup-benchmarking.json')
  backup_references_filename = File.join(site.config['source'], 'backup-references.json')

  if is_incremental
    # Read from backup and merge with incremental posts data
    begin
        backup_models_data = JSON.parse(File.read(backup_filename))
    rescue
      backup_models_data = Hash.new
    end
    begin
      backup_benchmarking_data = JSON.parse(File.read(backup_benchmarking_filename))
    rescue
      backup_benchmarking_data = Hash.new
    end

    begin
      backup_references_data = JSON.parse(File.read(backup_references_filename))
    rescue
      backup_references_data = Hash.new
    end

    # Remove deleted posts
    all_deleted_posts.each do |url|
      backup_models_data.delete(url)
      backup_references_data.delete(url)
      backup_benchmarking_data.delete(url)
    end

    models_json = backup_models_data.merge(models_json)
    models_benchmarking_json = backup_benchmarking_data.merge(models_benchmarking_json)
    models_references_json = backup_references_data.merge(models_references_json)
  end

  filename = File.join(site.config['destination'], 'models.json')
  File.write(filename, models_json.values.to_json)
  File.write(backup_filename, models_json.to_json)

  benchmarking_filename = File.join(site.config['destination'], 'benchmarking.json')
  File.write(benchmarking_filename, models_benchmarking_json.to_json)
  File.write(backup_benchmarking_filename, models_benchmarking_json.to_json)

  references_filename = File.join(site.config['destination'], 'references.json')
  File.write(references_filename, models_references_json.to_json)
  File.write(backup_references_filename, models_references_json.to_json)
end

Jekyll::Hooks.register :clean, :on_obsolete do |files|
  all_deleted_posts = files
              .select {|v| v.include?('/docs/_site') and v.end_with?('.html')}
              .map {|v| v.split('/docs/_site')[1]}
  if client
    client.delete_by_query index: ELASTICSEARCH_INDEX_NAME, body: {query: {bool: {must: [ {ids: {values: all_deleted_posts}}, {match: {origin: ORIGIN }} ]}}}
  end
end
