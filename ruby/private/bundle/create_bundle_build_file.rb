#!/usr/bin/env ruby
# frozen_string_literal: true

BUILD_HEADER = <<~MAIN_TEMPLATE
  load(
    "{workspace_name}//ruby:defs.bzl",
    "ruby_library",
  )
  load("@rules_pkg//:pkg.bzl", "pkg_tar")

  package(default_visibility = ["//visibility:public"])

  ruby_library(
    name = "bundler_setup",
    srcs = ["lib/bundler/setup.rb"],
    visibility = ["//visibility:private"],
  )

  ruby_library(
    name = "bundler",
    srcs = glob(
      include = [
        "bundler/**/*",
      ],
    ),
  )

MAIN_TEMPLATE

LOCAL_GEM_TEMPLATE = <<~LOCAL_GEM_TEMPLATE
  genrule(
    name = "{name}-gem-install",
    srcs = [],
    exec_tools = {dependencies},
    outs = ["{name}.tar.gz"],
    cmd = """
      export BUILD_HOME=$$PWD
      export GEM_HOME=$$BUILD_HOME/gem
      mkdir -p $$GEM_HOME

      # Unpack dependencies
      for tarball in {dep_tars}; do
        tar -xzf $$tarball -C $$GEM_HOME
      done

      cd $$BUILD_HOME
      tar -czf $@ -C $$GEM_HOME . >/dev/null
    """,
    message = "Installing gem: {name}:{version}",
    visibility = ["//visibility:public"],
  )
LOCAL_GEM_TEMPLATE

GEM_TEMPLATE = <<~GEM_TEMPLATE
  genrule(
    name = "{name}-gem-fetch",
    srcs = [],
    outs = ["{gem_name}.gem"],
    cmd = """
      TARGET_PLATFORM="x86_64-linux"
      gem fetch --platform $$TARGET_PLATFORM --no-prerelease --source {source} --version {version} {name} >/dev/null
      mv {name}-{version}*.gem $@ >/dev/null
    """,
    message = "Fetching gem: {name}:{version}",
    visibility = ["//visibility:public"],
  )

  genrule(
    name = "{name}-gem-install",
    srcs = [":{name}-gem-fetch"],
    exec_tools = {dependencies},
    outs = ["{name}.tar.gz"],
    cmd = """
      export BUILD_HOME=$$PWD
      cp $< $$BUILD_HOME

      export GEM_HOME=$$BUILD_HOME/gem
      mkdir -p $$GEM_HOME

      # Unpack dependencies
      for tarball in {dep_tars}; do
        tar -xzf $$tarball -C $$GEM_HOME
      done
      
      TARGET_PLATFORM="x86_64-linux"
      GEM_PLATFORM=$$(gem specification {name}-{version}.gem --yaml | grep 'platform: ' | awk '{print $$2}')
      ENV_PLATFORM=$$(gem environment platform)
      TARGET_PLATFORM_MATCH=$$(echo $$ENV_PLATFORM | grep $$TARGET_PLATFORM >/dev/null; echo $$?)
      GEM_PLATFORM_MATCH=$$(echo $$ENV_PLATFORM | grep $$GEM_PLATFORM >/dev/null; echo $$?)
      
      GEM_NO_EXTENSIONS=$$(gem specification {name}-{version}.gem --yaml | grep 'extensions: \\[\\]' >/dev/null; echo $$?) # 0 = no extensions

      if [ "$${TARGET_PLATFORM_MATCH}" -eq "0" ] || ( [ "$${GEM_NO_EXTENSIONS}" -eq "0" ] && [ "$${GEM_PLATFORM_MATCH}" -eq "0" ] )
      then
        gem install --platform $$TARGET_PLATFORM --no-document --no-wrappers --ignore-dependencies --local --version {version} {name} >/dev/null 2>&1
        # Symlink all the bin files
        cd $$GEM_HOME
        find ./bin -type l -exec sh -c 'if [[ $$(readlink $$0) == /* ]]; then (export TARGET_ABS=$$(readlink $$0) REPLACE="$${PWD}/"; rm $$0; ln -s ../"$${TARGET_ABS/"$${REPLACE}"/}" $$0); fi' {} \\;
        # Clean up files we don't need in the bundle
        rm -rf $$GEM_HOME/wrappers $$GEM_HOME/environment $$GEM_HOME/cache/{name}-{version}*.gem
      else
        echo ++++ {name} Incompatible platform or extensions to build - keep the gem for later install
        mkdir -p $$GEM_HOME/cache
        mv $$BUILD_HOME/{name}-{version}.gem $$GEM_HOME/cache
        ln -s {name}-{version}.gem $$GEM_HOME/cache/{name}-{version}-$$TARGET_PLATFORM.gem
      fi

      cd $$BUILD_HOME
      tar -czf $@ -C $$GEM_HOME . >/dev/null
    """,
    message = "Installing gem: {name}:{version}",
    visibility = ["//visibility:public"],
  )
GEM_TEMPLATE

GEM_GROUP = <<~GEM_GROUP
  pkg_tar(
    name = "gems-{group}",
    deps = {group_gem_installs},
    owner = "1000.1000",
    package_dir = "/vendor/bundle/ruby/{ruby_version}"
  )

GEM_GROUP

ALL_GEMS = <<~ALL_GEMS
  pkg_tar(
    name = "gems_cache",
    srcs = {cached_gems},
    owner = "1000.1000",
    package_dir = "/vendor/cache"
  )

  pkg_tar(
    name = "gems",
    deps = {gems},
    owner = "1000.1000",
    package_dir = "/vendor/bundle/ruby/{ruby_version}",
  )
ALL_GEMS

require 'bundler'
require 'json'
require 'stringio'
require 'fileutils'
require 'tempfile'

# colorization
class String
  def colorize(color_code)
    "\e[#{color_code}m#{self}\e[0m"
  end

  # @formatter:off
  def red;          colorize(31); end

  def green;        colorize(32); end

  def yellow;       colorize(33); end

  def blue;         colorize(34); end

  def pink;         colorize(35); end

  def light_blue;   colorize(36); end

  def orange;       colorize(52); end
  # @formatter:on
end

class Buildifier
  attr_reader :build_file, :output_file

  # @formatter:off
  class BuildifierError < StandardError; end

  class BuildifierNotFoundError < BuildifierError; end

  class BuildifierFailedError < BuildifierError; end

  class BuildifierNoBuildFileError < BuildifierError; end
  # @formatter:on

  def initialize(build_file)
    @build_file = build_file

    # For capturing buildifier output
    @output_file = ::Tempfile.new("/tmp/#{File.dirname(File.absolute_path(build_file))}/#{build_file}.stdout").path
  end

  def buildify!
    raise BuildifierNoBuildFileError, 'Can\'t find the BUILD file' unless File.exist?(build_file)

    # see if we can find buildifier on the filesystem
    buildifier = `bash -c 'command -v buildifier'`.strip

    raise BuildifierNotFoundError, 'Can\'t find buildifier' unless buildifier && File.executable?(buildifier)

    command = "#{buildifier} -v #{File.absolute_path(build_file)}"
    system("/usr/bin/env bash -c '#{command} 1>#{output_file} 2>&1'")
    code = $?

    return unless File.exist?(output_file)

    output = File.read(output_file).strip.gsub(Dir.pwd, '.').yellow
    begin
      FileUtils.rm_f(output_file)
    rescue StandardError
      nil
    end

    if code == 0
      puts 'Buildifier gave 👍 '.green + (output ? " and said: #{output}" : '')
    else
      raise BuildifierFailedError,
            "Generated BUILD file failed buildifier, with error:\n\n#{output.yellow}\n\n".red
    end
  end
end

class BundleBuildFileGenerator
  attr_reader :workspace_name,
              :repo_name,
              :build_file,
              :gemfile_lock,
              :srcs,
              :ruby_version

  DEFAULT_EXCLUDES = ['**/* *.*', '**/* */*'].freeze

  EXCLUDED_EXECUTABLES = %w(console setup).freeze

  def initialize(workspace_name:,
                 repo_name:,
                 build_file: 'BUILD.bazel',
                 gemfile_lock: 'Gemfile.lock',
                 srcs: nil)
    @workspace_name = workspace_name
    @repo_name      = repo_name
    @build_file     = build_file
    @gemfile_lock   = gemfile_lock
    @srcs           = srcs
    # This attribute returns 0 as the third minor version number, which happens to be
    # what Ruby uses in the PATH to gems, eg. ruby 2.6.5 would have a folder called
    # ruby/2.6.0/gems for all minor versions of 2.6.*
    @ruby_version ||= (RUBY_VERSION.split('.')[0..1] << 0).join('.')
  end

  def generate!
    # when we append to a string many times, using StringIO is more efficient.
    template_out = StringIO.new
    template_out.puts BUILD_HEADER
                        .gsub('{workspace_name}', workspace_name)
                        .gsub('{repo_name}', repo_name)
                        .gsub('{ruby_version}', ruby_version)
                        .gsub('{bundler_setup}', bundler_setup_require)

    # Get all the gems
    bundle = Bundler::LockfileParser.new(Bundler.read_file(gemfile_lock))
    bundle.specs.each { |spec| register_gem(spec, template_out) }

    register_bundler(template_out)

    remote_gems = bundle.specs
                        .delete_if{ |spec| spec.source.path? }
                        .map(&:name)
    template_out.puts ALL_GEMS
                        .gsub('{gems}', remote_gems.map { |g| ":#{g}-gem-install" }.to_s)
                        .gsub('{cached_gems}', remote_gems.map { |g| ":#{g}-gem-fetch" }.to_s)
                        .gsub('{ruby_version}', ruby_version)

    # Groups stuff - we can extract this from the gemfile.lock
    bundle_def    = Bundler::Definition.build(gemfile_lock.chomp('.lock'), gemfile_lock, {})
    # gems_by_group = bundle_def.groups.map{ |g| {g =>
    #   bundle_def
    #          .specs_for([g])
    #          .map(&:name)
    #          .flatten
    #          .uniq
    #          .select{|spec_name| remote_gems.include? spec_name}
    # }}.reduce Hash.new, :merge

    gems_by_group = bundle_def.groups.map{ |g| {g =>
       bundle_def
         .dependencies
         .select{|dep| dep.groups.include? g.to_sym}
         .map(&:name)
    }}.reduce Hash.new, :merge

    gems_by_group.each do |key, value|
      template_out.puts GEM_GROUP
                          .gsub('{group}', key.to_s)
                          .gsub('{group_gem_installs}', value.map{|s| ":#{s}-gem-install"}.compact.to_s)
                          .gsub('{ruby_version}', ruby_version)
    end

    ::File.open(build_file, 'w') { |f| f.puts template_out.string }
  end

  private

  def bundler_setup_require
    @bundler_setup_require ||= "-r#{runfiles_path('lib/bundler/setup.rb')}"
  end

  def runfiles_path(path)
    "${RUNFILES_DIR}/#{repo_name}/#{path}"
  end

  def register_gem(spec, template_out)
    template_to_use = (spec.source.path?) ? LOCAL_GEM_TEMPLATE : GEM_TEMPLATE

    template_out.puts template_to_use
                        .gsub('{name}', spec.name)
                        .gsub('{gem_name}', "#{spec.name}-#{spec.version}")
                        .gsub('{dependencies}', spec.dependencies.map{|spec| "#{spec.name}-gem-install"}.to_s)
                        .gsub('{dep_tars}', spec.dependencies.map{|spec| "$(location :#{spec.name}-gem-install)"}.join(' '))
                        .gsub('{version}', spec.version.version)
                        .gsub('{source}', spec.source.path? ? '' : spec.source.remotes.first.to_s)
                        .gsub('{ruby_version}', ruby_version)
  end

  def register_bundler(template_out)
    bundler_version = Bundler::VERSION

    template_out.puts GEM_TEMPLATE
                        .gsub('{name}', 'bundler')
                        .gsub('{gem_name}', "bundler-#{bundler_version}")
                        .gsub('{dependencies}', "[]")
                        .gsub('{dep_tars}', "")
                        .gsub('{version}', bundler_version)
                        .gsub('{source}', 'https://rubygems.org')
                        .gsub('{ruby_version}', ruby_version)
  end

  def gems_in_group(gems, group_name)
    gems
  end

  def include_array(gem_name)
    (includes[gem_name] || [])
  end

  def exclude_array(gem_name)
    (excludes[gem_name] || []) + DEFAULT_EXCLUDES
  end

  def to_flat_string(array)
    array.to_s.gsub(/[\[\]]/, '')
  end
end

# ruby ./create_bundle_build_file.rb "BUILD.bazel" "Gemfile.lock" "repo_name" "{}" "wsp_name"
if $0 == __FILE__
  if ARGV.length != 5
    warn("USAGE: #{$0} BUILD.bazel Gemfile.lock repo-name {srcs} workspace-name".orange)
    exit(1)
  end

  build_file, gemfile_lock, repo_name, srcs, workspace_name, * = *ARGV

  BundleBuildFileGenerator.new(build_file:     build_file,
                               gemfile_lock:   gemfile_lock,
                               repo_name:      repo_name,
                               srcs:           srcs,
                               workspace_name: workspace_name).generate!

  begin
    Buildifier.new(build_file).buildify!
    puts("Buildifier successful on file #{build_file} ")
  rescue Buildifier::BuildifierError => e
    warn("ERROR running buildifier on the generated build file [#{build_file}] ➔ #{e.message.orange}")
  end
end