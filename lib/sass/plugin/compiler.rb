require 'fileutils'

require 'sass'
# XXX CE: is this still necessary now that we have the compiler class?
require 'sass/callbacks'
require 'sass/plugin/configuration'
require 'sass/plugin/staleness_checker'

module Sass::Plugin

  # The Compiler class handles compilation of multiple files and/or directories,
  # including checking which CSS files are out-of-date and need to be updated
  # and calling Sass to perform the compilation on those files.
  #
  # {Sass::Plugin} uses this class to update stylesheets for a single application.
  # Unlike {Sass::Plugin}, though, the Compiler class has no global state,
  # and so multiple instances may be created and used independently.
  #
  # If you need to compile a Sass string into CSS,
  # please see the {Sass::Engine} class.
  #
  # Unlike {Sass::Plugin}, this class doesn't keep track of
  # whether or how many times a stylesheet should be updated.
  # Therefore, the following `Sass::Plugin` options are ignored by the Compiler:
  #
  # * `:never_update`
  # * `:always_check`
  class Compiler
    include Sass::Util
    include Configuration
    extend Sass::Callbacks

    # Creates a new compiler.
    #
    # @param options [{Symbol => Object}]
    #   See {file:SASS_REFERENCE.md#sass_options the Sass options documentation}.
    def initialize(options = {})
      self.options.merge!(options)
    end

    # Register a callback to be run after stylesheets are mass-updated.
    # This is run whenever \{#update\_stylesheets} is called,
    # unless the \{file:SASS_REFERENCE.md#never_update-option `:never_update` option}
    # is enabled.
    #
    # @yield [individual_files]
    # @yieldparam individual_files [<(String, String)>]
    #   Individual files to be updated, in addition to the directories
    #   specified in the options.
    #   The first element of each pair is the source file,
    #   the second is the target CSS file.
    define_callback :updating_stylesheets

    # Register a callback to be run after a single stylesheet is updated.
    # The callback is only run if the stylesheet is really updated;
    # if the CSS file is fresh, this won't be run.
    #
    # Even if the \{file:SASS_REFERENCE.md#full_exception-option `:full_exception` option}
    # is enabled, this callback won't be run
    # when an exception CSS file is being written.
    # To run an action for those files, use \{#on\_compilation\_error}.
    #
    # @yield [template, css]
    # @yieldparam template [String]
    #   The location of the Sass/SCSS file being updated.
    # @yieldparam css [String]
    #   The location of the CSS file being generated.
    # @yieldparam sourcemap [String]
    #   The location of the sourcemap being generated, if any.
    define_callback :updated_stylesheet

    # Register a callback to be run when Sass decides not to update a stylesheet.
    # In particular, the callback is run when Sass finds that
    # the template file and none of its dependencies
    # have been modified since the last compilation.
    #
    # Note that this is **not** run when the
    # \{file:SASS_REFERENCE.md#never-update_option `:never_update` option} is set,
    # nor when Sass decides not to compile a partial.
    #
    # @yield [template, css]
    # @yieldparam template [String]
    #   The location of the Sass/SCSS file not being updated.
    # @yieldparam css [String]
    #   The location of the CSS file not being generated.
    define_callback :not_updating_stylesheet

    # Register a callback to be run when there's an error
    # compiling a Sass file.
    # This could include not only errors in the Sass document,
    # but also errors accessing the file at all.
    #
    # @yield [error, template, css]
    # @yieldparam error [Exception] The exception that was raised.
    # @yieldparam template [String]
    #   The location of the Sass/SCSS file being updated.
    # @yieldparam css [String]
    #   The location of the CSS file being generated.
    define_callback :compilation_error

    # Register a callback to be run when Sass creates a directory
    # into which to put CSS files.
    #
    # Note that even if multiple levels of directories need to be created,
    # the callback may only be run once.
    # For example, if "foo/" exists and "foo/bar/baz/" needs to be created,
    # this may only be run for "foo/bar/baz/".
    # This is not a guarantee, however;
    # it may also be run for "foo/bar/".
    #
    # @yield [dirname]
    # @yieldparam dirname [String]
    #   The location of the directory that was created.
    define_callback :creating_directory

    # Register a callback to be run when Sass detects
    # that a template has been modified.
    # This is only run when using \{#watch}.
    #
    # @yield [template]
    # @yieldparam template [String]
    #   The location of the template that was modified.
    define_callback :template_modified

    # Register a callback to be run when Sass detects
    # that a new template has been created.
    # This is only run when using \{#watch}.
    #
    # @yield [template]
    # @yieldparam template [String]
    #   The location of the template that was created.
    define_callback :template_created

    # Register a callback to be run when Sass detects
    # that a template has been deleted.
    # This is only run when using \{#watch}.
    #
    # @yield [template]
    # @yieldparam template [String]
    #   The location of the template that was deleted.
    define_callback :template_deleted

    # Register a callback to be run when Sass deletes a CSS file.
    # This happens when the corresponding Sass/SCSS file has been deleted.
    #
    # @yield [filename]
    # @yieldparam filename [String]
    #   The location of the CSS file that was deleted.
    define_callback :deleting_css

    # Updates out-of-date stylesheets.
    #
    # Checks each Sass/SCSS file in {file:SASS_REFERENCE.md#template_location-option `:template_location`}
    # to see if it's been modified more recently than the corresponding CSS file
    # in {file:SASS_REFERENCE.md#css_location-option `:css_location`}.
    # If it has, it updates the CSS file.
    #
    # @param individual_files [Array<(String, String)>]
    #   A list of files to check for updates
    #   **in addition to those specified by the
    #   {file:SASS_REFERENCE.md#template_location-option `:template_location` option}.**
    #   The first string in each pair is the location of the Sass/SCSS file,
    #   the second is the location of the CSS file that it should be compiled to.
    def update_stylesheets(individual_files = [])
      individual_files = individual_files.dup
      Sass::Plugin.checked_for_updates = true
      staleness_checker = StalenessChecker.new(engine_options)

      template_location_array.each do |template_location, css_location|
        Sass::Util.glob(File.join(template_location, "**", "[^_]*.s[ca]ss")).sort.each do |file|
          # Get the relative path to the file
          name = file.sub(template_location.to_s.sub(/\/*$/, '/'), "")
          css = css_filename(name, css_location)
          sourcemap = Sass::Util.sourcemap_name(css) if engine_options[:sourcemap]
          individual_files << [file, css, sourcemap]
        end
      end

      individual_files.each do |file, css, sourcemap|
        # TODO: Does staleness_checker need to check the sourcemap file as well?
        if options[:always_update] || staleness_checker.stylesheet_needs_update?(css, file)
          update_stylesheet(file, css, sourcemap)
        else
          run_not_updating_stylesheet(file, css, sourcemap)
        end
      end
    end

    # Watches the template directory (or directories)
    # and updates the CSS files whenever the related Sass/SCSS files change.
    # `watch` never returns.
    #
    # Whenever a change is detected to a Sass/SCSS file in
    # {file:SASS_REFERENCE.md#template_location-option `:template_location`},
    # the corresponding CSS file in {file:SASS_REFERENCE.md#css_location-option `:css_location`}
    # will be recompiled.
    # The CSS files of any Sass/SCSS files that import the changed file will also be recompiled.
    #
    # Before the watching starts in earnest, `watch` calls \{#update\_stylesheets}.
    #
    # Note that `watch` uses the [Listen](http://github.com/guard/listen) library
    # to monitor the filesystem for changes.
    # Listen isn't loaded until `watch` is run.
    # The version of Listen distributed with Sass is loaded by default,
    # but if another version has already been loaded that will be used instead.
    #
    # @param individual_files [Array<(String, String)>]
    #   A list of files to watch for updates
    #   **in addition to those specified by the
    #   {file:SASS_REFERENCE.md#template_location-option `:template_location` option}.**
    #   The first string in each pair is the location of the Sass/SCSS file,
    #   the second is the location of the CSS file that it should be compiled to.
    def watch(individual_files = [])
      update_stylesheets(individual_files)

      require 'listen'

      template_paths = template_locations # cache the locations
      individual_files_hash = individual_files.inject({}) do |h, files|
        parent = File.dirname(files.first)
        (h[parent] ||= []) << files unless template_paths.include?(parent)
        h
      end
      directories = template_paths + individual_files_hash.keys +
        [{:relative_paths => true}]

      # TODO: Keep better track of what depends on what
      # so we don't have to run a global update every time anything changes.
      listener = Listen::MultiListener.new(*directories) do |modified, added, removed|
        modified.each do |f|
          parent = File.dirname(f)
          if files = individual_files_hash[parent]
            next unless files.first == f
          else
            next unless f =~ /\.s[ac]ss$/
          end
          run_template_modified(f)
        end

        added.each do |f|
          parent = File.dirname(f)
          if files = individual_files_hash[parent]
            next unless files.first == f
          else
            next unless f =~ /\.s[ac]ss$/
          end
          run_template_created(f)
        end

        removed.each do |f|
          parent = File.dirname(f)
          if files = individual_files_hash[parent]
            next unless files.first == f
            try_delete_css files[1]
          else
            next unless f =~ /\.s[ac]ss$/
            try_delete_css f.gsub(/\.s[ac]ss$/, '.css')
          end
          run_template_deleted(f)
        end

        update_stylesheets(individual_files)
      end

      # The native windows listener is much slower than the polling
      # option, according to https://github.com/nex3/sass/commit/a3031856b22bc834a5417dedecb038b7be9b9e3e#commitcomment-1295118
      listener.force_polling(true) if @options[:poll] || Sass::Util.windows?

      begin
        listener.start
      rescue Exception => e
        raise e unless e.is_a?(Interrupt)
      end
    end

    # Non-destructively modifies \{#options} so that default values are properly set,
    # and returns the result.
    #
    # @param additional_options [{Symbol => Object}] An options hash with which to merge \{#options}
    # @return [{Symbol => Object}] The modified options hash
    def engine_options(additional_options = {})
      opts = options.merge(additional_options)
      opts[:load_paths] = load_paths(opts)
      opts
    end

    # Compass expects this to exist
    def stylesheet_needs_update?(css_file, template_file)
      StalenessChecker.stylesheet_needs_update?(css_file, template_file)
    end

    private

    def update_stylesheet(filename, css, sourcemap)
      dir = File.dirname(css)
      unless File.exists?(dir)
        run_creating_directory dir
        FileUtils.mkdir_p dir
      end

      begin
        File.read(filename) unless File.readable?(filename) # triggers an error for handling
        engine_opts = engine_options(:css_filename => css, :filename => filename)
        mapping = nil
        engine = Sass::Engine.for_file(filename, engine_opts)
        if sourcemap
          rendered, mapping = engine.render_with_sourcemap(File.basename(sourcemap))
        else
          rendered = engine.render
        end
      rescue Exception => e
        compilation_error_occured = true
        run_compilation_error e, filename, css, sourcemap
        rendered = Sass::SyntaxError.exception_to_css(e, options)
      end

      write_file(css, rendered)
      write_file(sourcemap, mapping.to_json(:css_path => css, :sourcemap_path => sourcemap)) if mapping
      run_updated_stylesheet(filename, css, sourcemap) unless compilation_error_occured
    end

    def write_file(fileName, content)
      flag = 'w'
      flag = 'wb' if Sass::Util.windows? && options[:unix_newlines]
      File.open(fileName, flag) do |file|
        file.set_encoding(content.encoding) unless Sass::Util.ruby1_8?
        file.print(content)
      end
    end

    def try_delete_css(css)
      return unless File.exists?(css)
      run_deleting_css css
      File.delete css
    end

    def load_paths(opts = options)
      (opts[:load_paths] || []) + template_locations
    end

    def template_locations
      template_location_array.to_a.map {|l| l.first}
    end

    def css_locations
      template_location_array.to_a.map {|l| l.last}
    end

    def css_filename(name, path)
      "#{path}/#{name}".gsub(/\.s[ac]ss$/, '.css')
    end
  end
end
