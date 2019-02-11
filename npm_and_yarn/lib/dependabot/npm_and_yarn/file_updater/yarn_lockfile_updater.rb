# frozen_string_literal: true

require "dependabot/npm_and_yarn/file_updater"
require "dependabot/npm_and_yarn/file_parser"
require "dependabot/npm_and_yarn/update_checker/registry_finder"
require "dependabot/npm_and_yarn/native_helpers"
require "dependabot/shared_helpers"
require "dependabot/errors"

# rubocop:disable Metrics/ClassLength
module Dependabot
  module NpmAndYarn
    class FileUpdater
      class YarnLockfileUpdater
        require_relative "npmrc_builder"
        require_relative "package_json_updater"

        def initialize(dependencies:, dependency_files:, credentials:)
          @dependencies = dependencies
          @dependency_files = dependency_files
          @credentials = credentials
        end

        def updated_yarn_lock_content(yarn_lock)
          @updated_yarn_lock_content ||= {}
          if @updated_yarn_lock_content[yarn_lock.name]
            return @updated_yarn_lock_content[yarn_lock.name]
          end

          new_content = updated_yarn_lock(yarn_lock)

          @updated_yarn_lock_content[yarn_lock.name] =
            post_process_yarn_lockfile(new_content)
        end

        private

        attr_reader :dependencies, :dependency_files, :credentials

        UNREACHABLE_GIT = /ls-remote --tags --heads (?<url>.*)/.freeze
        TIMEOUT_FETCHING_PACKAGE =
          %r{(?<url>.+)/(?<package>[^/]+): ETIMEDOUT}.freeze
        INVALID_PACKAGE = /Can't add "(?<package_req>.*)": invalid/.freeze

        def top_level_dependencies
          dependencies.select(&:top_level?)
        end

        def sub_dependencies
          dependencies.reject(&:top_level?)
        end

        def updated_yarn_lock(yarn_lock)
          SharedHelpers.in_a_temporary_directory do
            write_temporary_dependency_files
            lockfile_name = Pathname.new(yarn_lock.name).basename.to_s
            path = Pathname.new(yarn_lock.name).dirname.to_s
            updated_files = run_current_yarn_update(
              path: path,
              lockfile_name: lockfile_name
            )
            updated_files.fetch(lockfile_name)
          end
        rescue SharedHelpers::HelperSubprocessFailed => error
          handle_yarn_lock_updater_error(error, yarn_lock)
        end

        def run_current_yarn_update(path:, lockfile_name:)
          top_level_dependency_updates = top_level_dependencies.map do |d|
            {
              name: d.name,
              version: d.version,
              requirements: requirements_for_path(d.requirements, path)
            }
          end

          run_yarn_updater(
            path: path,
            lockfile_name: lockfile_name,
            top_level_dependency_updates: top_level_dependency_updates
          )
        end

        def run_previous_yarn_update(path:, lockfile_name:)
          previous_top_level_dependencies = top_level_dependencies.map do |d|
            {
              name: d.name,
              version: d.previous_version,
              requirements: requirements_for_path(
                d.previous_requirements, path
              )
            }
          end

          run_yarn_updater(
            path: path,
            lockfile_name: lockfile_name,
            top_level_dependency_updates: previous_top_level_dependencies
          )
        end

        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/PerceivedComplexity
        def run_yarn_updater(path:, lockfile_name:,
                             top_level_dependency_updates:)
          SharedHelpers.with_git_configured(credentials: credentials) do
            Dir.chdir(path) do
              if top_level_dependency_updates.any?
                run_yarn_top_level_updater(
                  top_level_dependency_updates: top_level_dependency_updates
                )
              else
                run_yarn_subdependency_updater(lockfile_name: lockfile_name)
              end
            end
          end
        rescue SharedHelpers::HelperSubprocessFailed => error
          names = dependencies.map(&:name)
          package_missing = names.any? do |name|
            error.message.include?("find package \"#{name}")
          end

          raise unless error.message.include?("The registry may be down") ||
                       error.message.include?("ETIMEDOUT") ||
                       error.message.include?("ENOBUFS") ||
                       package_missing

          retry_count ||= 0
          retry_count += 1
          raise if retry_count > 2

          sleep(rand(3.0..10.0)) && retry
        end
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/PerceivedComplexity

        def run_yarn_top_level_updater(top_level_dependency_updates:)
          SharedHelpers.run_helper_subprocess(
            command: "node #{yarn_helper_path}",
            function: "update",
            args: [
              Dir.pwd,
              top_level_dependency_updates
            ]
          )
        end

        def run_yarn_subdependency_updater(lockfile_name:)
          SharedHelpers.run_helper_subprocess(
            command: "node #{yarn_helper_path}",
            function: "updateSubdependency",
            args: [Dir.pwd, lockfile_name]
          )
        end

        def requirements_for_path(requirements, path)
          return requirements if path.to_s == "."

          requirements.map do |r|
            next unless r[:file].start_with?("#{path}/")

            r.merge(file: r[:file].gsub(/^#{Regexp.quote("#{path}/")}/, ""))
          end.compact
        end

        # rubocop:disable Metrics/AbcSize
        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/PerceivedComplexity
        # rubocop:disable Metrics/MethodLength
        def handle_yarn_lock_updater_error(error, yarn_lock)
          # When the package.json doesn't include a name or version
          if error.message.match?(INVALID_PACKAGE)
            raise_resolvability_error(error, yarn_lock)
          end

          if error.message.include?("Couldn't find package")
            package_name =
              error.message.match(/package "(?<package_req>.*)?"/).
              named_captures["package_req"].
              split(/(?<=\w)\@/).first.
              gsub("%2f", "/")
            handle_missing_package(package_name, error, yarn_lock)
          end

          if error.message.match?(%r{/[^/]+: Not found})
            package_name =
              error.message.match(%r{/(?<package_name>[^/]+): Not found}).
              named_captures["package_name"].
              gsub("%2f", "/")
            handle_missing_package(package_name, error, yarn_lock)
          end

          # TODO: Move this logic to the version resolver and check if a new
          # version and all of its subdependencies are resolvable

          # Make sure the error in question matches the current list of
          # dependencies or matches an existing scoped package, this handles the
          # case where a new version (e.g. @angular-devkit/build-angular) relies
          # on a added dependency which hasn't been published yet under the same
          # scope (e.g. @angular-devkit/build-optimizer)
          #
          # This seems to happen when big monorepo projects publish all of their
          # packages sequentially, which might take enough time for Dependabot
          # to hear about a new version before all of its dependencies have been
          # published
          #
          # OR
          #
          # This happens if a new version has been published but npm is having
          # consistency issues and the version isn't fully available on all
          # queries
          if error.message.start_with?("Couldn't find any versions") &&
             dependencies_in_error_message?(error.message) &&
             resolvable_before_update?(yarn_lock)

            # Raise a bespoke error so we can capture and ignore it if
            # we're trying to create a new PR (which will be created
            # successfully at a later date)
            raise Dependabot::InconsistentRegistryResponse, error.message
          end

          if error.message.include?("Workspaces can only be enabled in priva")
            raise Dependabot::DependencyFileNotEvaluatable, error.message
          end

          if error.message.match?(UNREACHABLE_GIT)
            dependency_url = error.message.match(UNREACHABLE_GIT).
                             named_captures.fetch("url")

            raise Dependabot::GitDependenciesNotReachable, dependency_url
          end

          if error.message.match?(TIMEOUT_FETCHING_PACKAGE)
            handle_timeout(error.message, yarn_lock)
          end

          if error.message.start_with?("Couldn't find any versions") ||
             error.message.include?(": Not found")

            unless resolvable_before_update?(yarn_lock)
              raise_resolvability_error(error, yarn_lock)
            end

            # Dependabot has probably messed something up with the update and we
            # want to hear about it
            raise error
          end

          raise error
        end
        # rubocop:enable Metrics/AbcSize
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/PerceivedComplexity
        # rubocop:enable Metrics/MethodLength

        def resolvable_before_update?(yarn_lock)
          @resolvable_before_update ||= {}
          if @resolvable_before_update.key?(yarn_lock.name)
            return @resolvable_before_update[yarn_lock.name]
          end

          @resolvable_before_update[yarn_lock.name] =
            begin
              SharedHelpers.in_a_temporary_directory do
                write_temporary_dependency_files(update_package_json: false)
                lockfile_name = Pathname.new(yarn_lock.name).basename.to_s
                path = Pathname.new(yarn_lock.name).dirname.to_s
                run_previous_yarn_update(path: path,
                                         lockfile_name: lockfile_name)
              end

              true
            rescue SharedHelpers::HelperSubprocessFailed
              false
            end
        end

        def dependencies_in_error_message?(message)
          names = dependencies.map { |dep| dep.name.split("/").first }
          # Example format: Couldn't find any versions for
          # "@dependabot/dummy-pkg-b" that matches "^1.3.0"
          names.any? do |name|
            message.match?(%r{"#{Regexp.quote(name)}["\/]})
          end
        end

        def write_temporary_dependency_files(update_package_json: true)
          write_lockfiles

          File.write(".npmrc", npmrc_content)

          package_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)

            updated_content =
              if update_package_json && top_level_dependencies.any?
                updated_package_json_content(file)
              else
                file.content
              end

            updated_content = replace_ssh_sources(updated_content)

            # A bug prevents Yarn recognising that a directory is part of a
            # workspace if it is specified with a `./` prefix.
            updated_content = remove_workspace_path_prefixes(updated_content)

            updated_content = sanitized_package_json_content(updated_content)
            File.write(file.name, updated_content)
          end
        end

        def write_lockfiles
          yarn_locks.each do |f|
            FileUtils.mkdir_p(Pathname.new(f.name).dirname)

            if top_level_dependencies.any?
              File.write(f.name, f.content)
            else
              File.write(f.name, prepared_yarn_lockfile_content(f.content))
            end
          end
        end

        # Duplicated in SubdependencyVersionResolver
        # Remove the dependency we want to update from the lockfile and let
        # yarn find the latest resolvable version and fix the lockfile
        def prepared_yarn_lockfile_content(content)
          sub_dependencies.map(&:name).reduce(content) do |result, name|
            result.gsub(/^#{Regexp.quote(name)}\@.*?\n\n/m, "")
          end
        end

        def replace_ssh_sources(content)
          updated_content = content

          git_ssh_requirements_to_swap.each do |req|
            new_req = req.gsub(%r{git\+ssh://git@(.*?)[:/]}, 'https://\1/')
            updated_content = updated_content.gsub(req, new_req)
          end

          updated_content
        end

        def remove_workspace_path_prefixes(content)
          json = JSON.parse(content)
          return content unless json.key?("workspaces")

          workspace_object = json.fetch("workspaces")
          paths_array =
            if workspace_object.is_a?(Hash)
              workspace_object.values_at("packages", "nohoist").
                flatten.compact
            elsif workspace_object.is_a?(Array) then workspace_object
            else raise "Unexpected workspace object"
            end

          paths_array.each { |path| path.gsub!(%r{^\./}, "") }

          json.to_json
        end

        def git_ssh_requirements_to_swap
          return @git_ssh_requirements_to_swap if @git_ssh_requirements_to_swap

          git_dependencies =
            dependencies.
            select do |dep|
              dep.requirements.any? { |r| r.dig(:source, :type) == "git" }
            end

          @git_ssh_requirements_to_swap = []

          package_files.each do |file|
            NpmAndYarn::FileParser::DEPENDENCY_TYPES.each do |t|
              JSON.parse(file.content).fetch(t, {}).each do |nm, requirement|
                next unless git_dependencies.map(&:name).include?(nm)
                next unless requirement.start_with?("git+ssh:")

                req = requirement.split("#").first
                @git_ssh_requirements_to_swap << req
              end
            end
          end

          @git_ssh_requirements_to_swap
        end

        def post_process_yarn_lockfile(lockfile_content)
          updated_content = lockfile_content

          git_ssh_requirements_to_swap.each do |req|
            new_req = req.gsub(%r{git\+ssh://git@(.*?)[:/]}, 'https://\1/')
            updated_content = updated_content.gsub(new_req, req)
          end

          if remove_integrity_lines?
            updated_content = remove_integrity_lines(updated_content)
          end

          updated_content
        end

        def remove_integrity_lines?
          yarn_locks.none? { |f| f.content.include?(" integrity sha") }
        end

        def remove_integrity_lines(content)
          content.lines.reject { |l| l.match?(/\s*integrity sha/) }.join
        end

        def lockfile_dependencies(lockfile)
          @lockfile_dependencies ||= {}
          @lockfile_dependencies[lockfile.name] ||=
            NpmAndYarn::FileParser.new(
              dependency_files: [lockfile, *package_files],
              source: nil,
              credentials: credentials
            ).parse
        end

        def handle_missing_package(package_name, error, yarn_lock)
          missing_dep = lockfile_dependencies(yarn_lock).
                        find { |dep| dep.name == package_name }

          raise_resolvability_error(error, yarn_lock) unless missing_dep

          reg = NpmAndYarn::UpdateChecker::RegistryFinder.new(
            dependency: missing_dep,
            credentials: credentials,
            npmrc_file: dependency_files.
                        find { |f| f.name.end_with?(".npmrc") },
            yarnrc_file: dependency_files.
                         find { |f| f.name.end_with?(".yarnrc") }
          ).registry

          # Sanitize Gemfury URLs
          reg = reg.gsub(%r{(?<=\.fury\.io)/.*}, "")
          return if central_registry?(reg) && !package_name.start_with?("@")

          raise PrivateSourceAuthenticationFailure, reg
        end

        def central_registry?(registry)
          NpmAndYarn::FileParser::CENTRAL_REGISTRIES.any? do |r|
            r.include?(registry)
          end
        end

        def raise_resolvability_error(error, yarn_lock)
          dependency_names = dependencies.map(&:name).join(", ")
          msg = "Error whilst updating #{dependency_names} in "\
                "#{yarn_lock.path}:\n#{error.message}"
          raise Dependabot::DependencyFileNotResolvable, msg
        end

        def handle_timeout(message, yarn_lock)
          url = message.match(TIMEOUT_FETCHING_PACKAGE).named_captures["url"]
          return if url.start_with?("https://registry.npmjs.org")

          package_name =
            message.match(TIMEOUT_FETCHING_PACKAGE).
            named_captures["package"].gsub("%2f", "/").gsub("%2F", "/")

          dep = lockfile_dependencies(yarn_lock).
                find { |d| d.name == package_name }
          return unless dep

          raise PrivateSourceTimedOut, url.gsub(%r{https?://}, "")
        end

        def npmrc_content
          NpmrcBuilder.new(
            credentials: credentials,
            dependency_files: dependency_files
          ).npmrc_content
        end

        def updated_package_json_content(file)
          @updated_package_json_content ||= {}
          @updated_package_json_content[file.name] ||=
            PackageJsonUpdater.new(
              package_json: file,
              dependencies: top_level_dependencies
            ).updated_package_json.content
        end

        def npmrc_disables_lockfile?
          npmrc_content.match?(/^package-lock\s*=\s*false/)
        end

        def sanitized_package_json_content(content)
          content.
            gsub(/\{\{.*?\}\}/, "something"). # {{ name }} syntax not allowed
            gsub(/(?<!\\)\\ /, " ").          # escaped whitespace not allowed
            gsub(%r{^\s*//.*}, " ")           # comments are not allowed
        end

        def yarn_locks
          @yarn_locks ||=
            dependency_files.
            select { |f| f.name.end_with?("yarn.lock") }
        end

        def package_files
          dependency_files.select { |f| f.name.end_with?("package.json") }
        end

        def yarn_helper_path
          NativeHelpers.yarn_helper_path
        end
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength