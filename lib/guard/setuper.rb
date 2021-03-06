require 'thread'
require 'listen'
require 'guard/options'

module Guard

  module Setuper

    DEFAULT_OPTIONS = {
      clear: false,
      notify: true,
      debug: false,
      group: [],
      plugin: [],
      watchdir: nil,
      guardfile: nil,
      no_interactions: false,
      no_bundler_warning: false,
      show_deprecations: false,
      latency: nil,
      force_polling: false
    }
    DEFAULT_GROUPS = [:default]

    # Initializes the Guard singleton:
    #
    # * Initialize the internal Guard state;
    # * Create the interactor when necessary for user interaction;
    # * Select and initialize the file change listener.
    #
    # @option options [Boolean] clear if auto clear the UI should be done
    # @option options [Boolean] notify if system notifications should be shown
    # @option options [Boolean] debug if debug output should be shown
    # @option options [Array<String>] group the list of groups to start
    # @option options [Array<String>] watchdir the directories to watch
    # @option options [String] guardfile the path to the Guardfile
    #
    # @return [Guard] the Guard singleton
    #
    def setup(opts = {})
      _reset_lazy_accessors
      @running   = true
      @lock      = Mutex.new
      @opts      = opts
      @watchdirs = [Dir.pwd]
      @runner    = ::Guard::Runner.new

      if options.watchdir
        # Ensure we have an array
        @watchdirs = Array(options.watchdir).map { |dir| File.expand_path dir }
      end

      ::Guard::UI.clear(force: true)
      _setup_debug if options.debug
      _setup_listener
      _setup_signal_traps

      reset_groups
      reset_plugins
      reset_scope

      evaluate_guardfile

      setup_scope(groups: options.group, plugins: options.plugin)

      _setup_notifier

      self
    end

    # Lazy initializer for Guard's options hash
    #
    def options
      @options ||= ::Guard::Options.new(@opts || {}, DEFAULT_OPTIONS)
    end

    # Lazy initializer for Guardfile evaluator
    #
    def evaluator
      @evaluator ||= ::Guard::Guardfile::Evaluator.new(@opts || {})
    end

    # Lazy initializer the interactor unless the user has specified not to.
    #
    def interactor
      return if options.no_interactions || !::Guard::Interactor.enabled

      @interactor ||= ::Guard::Interactor.new
    end

    # Clear Guard's options hash
    #
    def clear_options
      @options = nil
    end

    # Initializes the groups array with the default group(s).
    #
    # @see DEFAULT_GROUPS
    #
    def reset_groups
      @groups = DEFAULT_GROUPS.map { |name| Group.new(name) }
    end

    # Initializes the plugins array to an empty array.
    #
    # @see Guard.plugins
    #
    def reset_plugins
      @plugins = []
    end

    # Initializes the scope hash to `{ groups: [], plugins: [] }`.
    #
    # @see Guard.setup_scope
    #
    def reset_scope
      @scope = { groups: [], plugins: [] }
    end

    # Stores the scopes defined by the user via the `--group` / `-g` option (to run
    # only a specific group) or the `--plugin` / `-P` option (to run only a
    # specific plugin).
    #
    # @see CLI#start
    # @see Dsl#scope
    #
    def setup_scope(new_scope)
      if new_scope[:groups] && new_scope[:groups].any?
        scope[:groups]  = new_scope[:groups].map { |group| ::Guard.add_group(group) }
      end

      if new_scope[:plugins] && new_scope[:plugins].any?
        scope[:plugins] = new_scope[:plugins].map { |plugin| ::Guard.plugin(plugin) }
      end
    end

    # Evaluates the Guardfile content. It displays an error message if no
    # Guard plugins are instantiated after the Guardfile evaluation.
    #
    # @see Guard::Guardfile::Evaluator#evaluate_guardfile
    #
    def evaluate_guardfile
      evaluator.evaluate_guardfile
      ::Guard::UI.error 'No plugins found in Guardfile, please add at least one.' if plugins.empty?
    end

    private

    def _reset_lazy_accessors
      @options    = nil
      @evaluator  = nil
      @interactor = nil
    end

    # Sets up various debug behaviors:
    #
    # * Abort threads on exception;
    # * Set the logging level to `:debug`;
    # * Modify the system and ` methods to log themselves before being executed
    #
    # @see #_debug_command_execution
    #
    def _setup_debug
      Thread.abort_on_exception = true
      ::Guard::UI.options.level = :debug
      _debug_command_execution
    end

    # Initializes the listener and registers a callback for changes.
    #
    def _setup_listener
      listener_callback = lambda do |modified, added, removed|
        # Convert to relative paths (respective to the watchdir it came from)
        @watchdirs.each do |watchdir|
          [modified, added, removed].each do |paths|
            paths.map! do |path|
              if path.start_with? watchdir
                path.sub "#{watchdir}#{File::SEPARATOR}", ''
              else
                path
              end
            end
          end
        end
        evaluator.reevaluate_guardfile if ::Guard::Watcher.match_guardfile?(modified)

        within_preserved_state do
          runner.run_on_changes(modified, added, removed)
        end
      end

      listener_options = {}
      %w[latency force_polling].each do |option|
        listener_options[option.to_sym] = options.send(option) if options.send(option)
      end

      listen_args = @watchdirs + [listener_options]
      @listener = Listen.to(*listen_args, &listener_callback)
    end

    # Sets up traps to catch signals used to control Guard.
    #
    # Currently two signals are caught:
    # - `USR1` which pauses listening to changes.
    # - `USR2` which resumes listening to changes.
    # - 'INT' which is delegated to Pry if active, otherwise stops Guard.
    #
    def _setup_signal_traps
      unless defined?(JRUBY_VERSION)
        if Signal.list.keys.include?('USR1')
          Signal.trap('USR1') { ::Guard.pause unless listener.paused? }
        end

        if Signal.list.keys.include?('USR2')
          Signal.trap('USR2') { ::Guard.pause if listener.paused? }
        end

        if Signal.list.keys.include?('INT')
          Signal.trap('INT') do
            if interactor && interactor.thread
              interactor.thread.raise(Interrupt)
            else
              ::Guard.stop
            end
          end
        end
      end
    end

    # Enables or disables the notifier based on user's configurations.
    #
    def _setup_notifier
      if options.notify && ENV['GUARD_NOTIFY'] != 'false'
        ::Guard::Notifier.turn_on
      else
        ::Guard::Notifier.turn_off
      end
    end

    # Adds a command logger in debug mode. This wraps common command
    # execution functions and logs the executed command before execution.
    #
    def _debug_command_execution
      Kernel.send(:alias_method, :original_system, :system)
      Kernel.send(:define_method, :system) do |command, *args|
        ::Guard::UI.debug "Command execution: #{ command } #{ args.join(' ') }"
        Kernel.send :original_system, command, *args
      end

      Kernel.send(:alias_method, :original_backtick, :'`')
      Kernel.send(:define_method, :'`') do |command|
        ::Guard::UI.debug "Command execution: #{ command }"
        Kernel.send :original_backtick, command
      end
    end

  end
end
