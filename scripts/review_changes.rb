# frozen_string_literal: true

require 'safe_yaml'
require 'uri'
require 'octokit'
require 'pathname'
require 'graphql/client'
require 'graphql/client/http'

require 'open3'

require 'up_for_grabs_tooling'

def run_command(cmd)
  stdout, stderr, status = Open3.capture3(cmd)

  {
    stdout:,
    stderr:,
    exit_code: status.exitstatus
  }
end

FOUND_PROJECT_FILES_HEADER = ":wave: I'm a robot checking the state of this pull request to save the human reviewers time. " \
                             "I noticed this PR added or modified the data files under `_data/projects/` so I had a look at what's changed." \
                             "\n\nAs you make changes to this pull request, I'll re-run these checks.\n\n"

SKIP_PULL_REQUEST_MESSAGE = ":wave: I'm a robot checking the state of this pull request to save the human reviewers time. " \
                            "I don't see any changes under `_data/projects/` so I don't have any feedback here." \
                            "\n\nAs you make changes to this pull request, I'll re-run these checks.\n\n"

ALLOWED_EXTENSIONS = ['.yml'].freeze

def get_validation_message(result)
  path = result[:project].relative_path

  case result[:kind]
  when 'valid'
    "#### `#{path}` :white_check_mark:\n#{result[:message]}"
  when 'validation'
    message = result[:validation_errors].map { |e| "> - #{e}" }.join "\n"
    "#### `#{path}` :x:\nI had some troubles parsing the project file, or there were fields that are missing that I need.\n\nHere's the details:\n#{message}"
  when 'tags'
    message = result[:tags_errors].map { |e| "> - #{e}" }.join "\n"
    "#### `#{path}` :x:\nI have some suggestions about the tags used in the project:\n\n#{message}"
  when 'link-url'
    "#### `#{path}` :x:\nThe `upforgrabs.url` value #{result[:url]} is not a valid URL - please check and update the value."
  when 'repository', 'label'
    "#### `#{path}` :x:\n#{result[:message]}"
  else
    "#### `#{path}` :question:\nIt appears that the result is of a type that I don't know how to handle. Please seek assistance from @shiftkey to address this issue."
  end
end

def generate_review_comment(dir, files)
  projects = files.map do |f|
    full_path = File.join(dir, f)

    Project.new(f, full_path) if File.exist?(full_path)
  end

  projects.compact!
  markdown_body = FOUND_PROJECT_FILES_HEADER
  messages = []

  projects_without_valid_extensions = projects.reject { |p| ALLOWED_EXTENSIONS.include? File.extname(p.relative_path) }

  if projects_without_valid_extensions.any?
    messages = ['#### Unexpected files found in project directory']
    projects_without_valid_extensions.each do |p|
      messages << " - `#{p.relative_path}`"
    end
    messages << 'All files under `_data/projects/` must end with `.yml` to be listed on the site'
  elsif projects.count > 2
    results = projects.map { |p| review_project(p) }
    valid_projects, projects_with_errors = results.partition { |r| r[:kind] == 'valid' }

    if projects_with_errors.empty?
      messages = [
        "#### **#{valid_projects.count}** projects without issues :white_check_mark:",
        'Everything should be good to merge!'
      ]
    else
      messages = ["#### **#{valid_projects.count}** projects without issues :white_check_mark:"]
      messages << projects_with_errors.map { |result| get_validation_message(result) }
    end
  else
    messages = projects.map { |p| review_project(p) }.map { |r| get_validation_message(r) }
  end

  markdown_body + messages.join("\n\n")
end

def review_project(project)
  validation_errors = SchemaValidator.validate(project)

  return { project:, kind: 'validation', validation_errors: } if validation_errors.any?

  tags_errors = TagsValidator.validate(project)

  return { project:, kind: 'tags', tags_errors: } if tags_errors.any?

  yaml = project.read_yaml
  link = yaml['upforgrabs']['link']

  return { project:, kind: 'link-url', url: link } unless valid_url?(link)

  return { project:, kind: 'valid' } unless project.github_project?

  repository_error = repository_check(project)

  return { project:, kind: 'repository', message: repository_error } unless repository_error.nil?

  label_result = label_validation_message(project)

  kind = label_result.key?(:reason) ? 'label' : 'valid'

  { project:, kind:, message: label_result[:message] }
end

def repository_check(project)
  # TODO: this looks for GITHUB_TOKEN underneath - it should not be hard-coded like this
  # TODO: cleanup the GITHUB_TOKEN setting once this is decoupled from the environment variable
  result = GitHubRepositoryActiveCheck.run(project)

  if result[:rate_limited]
    # logger.info 'This script is currently rate-limited by the GitHub API'
    # logger.info 'Marking as inconclusive to indicate that no further work will be done here'
    return nil
  end

  return "The GitHub repository '#{project.github_owner_name_pair}' has been marked as archived, which suggests it is not active." if result[:reason] == 'archived'

  return "The GitHub repository '#{project.github_owner_name_pair}' cannot be found. Please confirm the location of the project." if result[:reason] == 'missing'

  return "The GitHub repository '#{result[:old_location]}' is now at '#{result[:location]}'. Please update this project before this is merged." if result[:reason] == 'redirect'

  return "The GitHub repository '#{project.github_owner_name_pair}' could not be confirmed. Error details: #{result[:error]}" if result[:reason] == 'error'

  nil
end

def label_validation_message(project)
  result = GitHubRepositoryLabelActiveCheck.run(project)

  if result[:rate_limited]
    # logger.info 'This script is currently rate-limited by the GitHub API'
    # logger.info 'Marking as inconclusive to indicate that no further work will be done here'
    return { reason: :rate_limited }
  end

  return "An error occurred while querying for the project label. Details: #{result[:error].inspect}" if result[:reason] == 'error'

  if result[:reason] == 'repository-missing'
    return {
      reason: :error,
      message: "I couldn't find the GitHub repository '#{project.github_owner_name_pair}' that was used in the `upforgrabs.link` value. " \
               "Please confirm this is correct or hasn't been mis-typed."
    }
  end

  if result[:reason] == 'missing'
    return {
      reason: :error,
      message: "I couldn't find the label that was used in the `upforgrabs.link` value: '#{result[:name]}'. Please update the configuration to match the right label in this repository."
    }
  end

  yaml = project.read_yaml
  label = yaml['upforgrabs']['name']

  if result[:reason] == 'missing'
    return {
      reason: :error,
      message: "The `upforgrabs.name` value '#{label}' isn't in use on the project in GitHub. " \
               'This might just be a mistake due because of copy-pasting the reference template or be mis-typed. ' \
               "Please check the list of labels at https://github.com/#{project.github_owner_name_pair}/labels and update the project file to use the correct label."
    }
  end

  link = yaml['upforgrabs']['link']
  url = result[:url]

  link_needs_rewriting = link != url && link.include?('/labels/')

  if link_needs_rewriting
    # TODO: can we turn this into a PR suggestion?
    return {
      reason: :error,
      message: "The label '#{label}' for GitHub repository '#{project.github_owner_name_pair}' does not match the specified `upforgrabs.link` value. Please update it to `#{url}`."
    }
  end

  if result[:reason] == 'found'
    issue_count = result[:count]

    if issue_count.zero?
      return {
        message: "A label named [#{result[:name]}](#{result[:url]}) has been found on GitHub but it doesn't contain any open issues. This won't be listed on the site when this is merged but is otherwise fine to proceed."
      }
    else
      issue_with_suffix = issue_count == 1 ? 'issue' : 'issues'
      return {
        message: "A label named [#{result[:name]}](#{result[:url]}) has been found on GitHub and it currently has #{issue_count} #{issue_with_suffix} - this should be ready to merge!"
      }
    end
  end

  {
    reason: :error,
    message: 'Unexpected result found, please review the logs to see more information'
  }
end

def valid_url?(url)
  uri = URI.parse(url)
  uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
rescue URI::InvalidURIError
  false
end

head_sha = ENV.fetch('HEAD_SHA', nil)
base_sha = ENV.fetch('BASE_SHA', nil)
git_remote_url = ENV.fetch('GIT_REMOTE_URL', nil)
dir = ENV.fetch('GITHUB_WORKSPACE', nil)

range = "#{base_sha}...#{head_sha}"

if git_remote_url
  # fetching the fork repository so that our commits are in this repository
  # for processing and comparison with the base branch
  remote_result = run_command "git -C '#{dir}' remote add fork #{git_remote_url} -f"

  if remote_result[:exit_code] == 3
    run "git -C '#{dir}' remote rm fork"
    remote_result = run "git -C '#{dir}' remote add fork #{git_remote_url} -f"
  end

  if remote_result[:exit_code] != 0
  warn 'A git error occurred while trying to diff the two commits'
  warn
  warn "stderr: '#{result[:stderr]}'"
  warn
  warn "stdout: '#{result[:stdout]}'"
end
    warn 'A git error occurred while trying to add the remote #{git_remote_url}'
    warn 'exit code: #{remote_result[:exit_code]}'
    warn 'stderr: #{remote_result[:stderr]}'
    warn 'stdout: #{remote_result[:stdout]}' "A git error occurred while trying to add the remote #{git_remote_url}"
    warn
    warn "exit code: #{remote_result[:exit_code]}"
    warn
    warn "stderr: '#{remote_result[:stderr]}'"
    warn
    warn "stdout: '#{remote_result[:stdout]}'"
    return
  end
end

# TODO: Add code to handle the failed GitHub Actions run and error logs
puts "The GitHub Actions run failed with the following error logs:"
puts ""
