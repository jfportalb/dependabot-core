# frozen_string_literal: true

require "digest"

require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/dependency_group"
require "dependabot/pull_request_creator/branch_namer/dependency_group_strategy"

RSpec.describe Dependabot::PullRequestCreator::BranchNamer::DependencyGroupStrategy do
  subject(:namer) do
    described_class.new(
      dependencies: dependencies,
      files: [gemfile],
      target_branch: target_branch,
      separator: separator,
      dependency_group: dependency_group
    )
  end

  let(:dependencies) { [dependency] }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: "business",
      version: "1.5.0",
      previous_version: "1.4.0",
      package_manager: "bundler",
      requirements: {},
      previous_requirements: {}
    )
  end
  let(:gemfile) do
    Dependabot::DependencyFile.new(
      name: "Gemfile",
      content: "anything",
      directory: directory
    )
  end

  let(:dependency_group) do
    Dependabot::DependencyGroup.new(name: "my-dependency-group", rules: anything)
  end

  describe "#new_branch_name" do
    context "with defaults for separator, target branch and files in the root directory" do
      let(:directory) { "/" }
      let(:target_branch) { nil }
      let(:separator) { "/" }

      it "returns the name of the dependency group prefixed correctly" do
        expect(namer.new_branch_name).to start_with("dependabot/bundler/my-dependency-group")
      end

      it "generates a deterministic branch name for a given set of dependencies" do
        branch_name = namer.new_branch_name
        new_namer = described_class.new(
          dependencies: dependencies,
          files: [gemfile],
          target_branch: target_branch,
          separator: separator,
          dependency_group: dependency_group
        )
        sleep 1 # ensure the timestamp changes
        expect(new_namer.new_branch_name).to eql(branch_name)
      end

      it "generates a different branch name for a different set of dependencies for the same group" do
        removed_dependency = Dependabot::Dependency.new(
          name: "old_business",
          version: "1.4.0",
          previous_version: "1.4.0",
          package_manager: "bundler",
          requirements: {},
          previous_requirements: {},
          removed: true
        )

        new_namer = described_class.new(
          dependencies: [dependency, removed_dependency],
          files: [gemfile],
          target_branch: target_branch,
          separator: separator,
          dependency_group: dependency_group
        )
        expect(new_namer.new_branch_name).not_to eql(namer.new_branch_name)
      end

      it "generates the same branch name regardless of the order of dependencies" do
        removed_dependency = Dependabot::Dependency.new(
          name: "old_business",
          version: "1.4.0",
          previous_version: "1.4.0",
          package_manager: "bundler",
          requirements: {},
          previous_requirements: {},
          removed: true
        )

        forward_namer = described_class.new(
          dependencies: [dependency, removed_dependency],
          files: [gemfile],
          target_branch: target_branch,
          separator: separator,
          dependency_group: dependency_group
        )

        backward_namer = described_class.new(
          dependencies: [removed_dependency, dependency],
          files: [gemfile],
          target_branch: target_branch,
          separator: separator,
          dependency_group: dependency_group
        )

        expect(forward_namer.new_branch_name).to eql(backward_namer.new_branch_name)
      end
    end

    context "with a custom separator" do
      let(:directory) { "/" }
      let(:target_branch) { nil }
      let(:separator) { "_" }

      it "returns the name of the dependency group prefixed correctly" do
        expect(namer.new_branch_name).to start_with("dependabot_bundler_my-dependency-group")
      end
    end

    context "for files in a non-root directory" do
      let(:directory) { "rails app/" } # let's make sure we deal with spaces too
      let(:target_branch) { nil }
      let(:separator) { "/" }

      it "returns the name of the dependency group prefixed correctly" do
        expect(namer.new_branch_name).to start_with("dependabot/bundler/rails-app/my-dependency-group")
      end
    end

    context "targeting a branch" do
      let(:directory) { "/" }
      let(:target_branch) { "develop" }
      let(:separator) { "/" }

      it "returns the name of the dependency group prefixed correctly" do
        expect(namer.new_branch_name).to start_with("dependabot/bundler/develop/my-dependency-group")
      end
    end

    context "for files in a non-root directory targetting a branch" do
      let(:directory) { "rails-app/" }
      let(:target_branch) { "develop" }
      let(:separator) { "_" }

      it "returns the name of the dependency group prefixed correctly" do
        expect(namer.new_branch_name).to start_with("dependabot_bundler_rails-app_develop_my-dependency-group")
      end
    end
  end
end
