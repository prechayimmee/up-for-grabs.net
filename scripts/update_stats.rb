# frozen_string_literal: true

require 'safe_yaml/load'
require 'uri'
require 'webmock/rspec'
require 'pathname'
require 'graphql/client'
require 'graphql/client/http'

require 'up_for_grabs_tooling'

def update(project, apply_changes: false)
  return unless project.github_project?

  result = UpForGrabsTooling::GitHubRepositoryLabelActiveCheck.run(project)

  warn "Project: #{project.github_owner_name_pair} returned #{result.inspect}"

  if result[:rate_limited]
    warn 'The GitHub Actions run has been rate-limited. No further work will be done here.'
    warn 'Marking as inconclusive to indicate that no further work will be done here'
    exit 0
  end

  if result[:reason] == 'repository-missing'
    warn "The GitHub repository '#{project.github_owner_name_pair}'! Please confirm the location of the project."
    return
  end

  if result[:reason] == 'issues-disabled'
    warn "The GitHub repository '#{project.github_owner_name_pair}' has issues disabled, and should be cleaned up with the next deprecation run."
    return
  end

  if result[:reason] == 'api-request-error'
    warn "An error occurred: #{result[:error]}"
    warn "Error occurred in project: #{project.github_owner_name_pair}"
    next
  end

  obj = project.read_yaml
  label = obj['upforgrabs']['name']

  if result[:reason] == 'missing-label'
    warn "The label '#{label}' for GitHub repository '#{project.github_owner_name_pair}' could not be found. Please ensure this points to a valid label used in the project."
    return
  end

  link = obj['upforgrabs']['link']

  url = result[:url]

  needs_link_rewriting = link != url && link.include?('/labels/')

  unless apply_changes
    warn "The label link for '#{label}' in project '#{project.relative_path}' is out of sync with what is found in the 'upforgrabs' element. Ensure this is updated to '#{url}'" if needs_link_rewriting
    warn "The label link for '#{label}' in project '#{project.relative_path}' needs to be updated to '#{url}'" if needs_link_rewriting
    return
  end

  if needs_link_rewriting
  obj.store('upforgrabs', 'name' => label, 'link' => url)
  obj.store('stats', 'issue-count' => result[:count], 'fork-count' => result[:fork_count])
end

  if result[:last_updated].nil?
    obj.store('stats',
              'issue-count' => result[:count],
              'fork-count' => result[:fork_count])
  else
    obj.store('stats',
              'issue-count' => result[:count],
              'last-updated' => result[:last_updated],
              'fork-count' => result[:fork_count])
  end

  project.write_yaml(obj)
end

current_repo = ENV['GITHUB_REPOSITORY'] || raise('GITHUB_REPOSITORY environment variable is missing')

warn "Inspecting projects files for '#{current_repo}'"

start = Time.now

root_directory = ENV['GITHUB_WORKSPACE'] || raise('GITHUB_WORKSPACE environment variable is missing')
apply_changes = ENV['APPLY_CHANGES'] || raise('APPLY_CHANGES environment variable is missing or has an invalid value')
token = ENV['GITHUB_TOKEN'] || raise('GITHUB_TOKEN environment variable is missing')

client = Octokit::Client.new(access_token: token)
prs = client.pulls current_repo

existing_pull_request = find_existing_pull_request(prs)

if existing_pull_request
  warn "There is a current PR open to update stats ##{found_pr.number} - review and merge that before we go again"
  exit 0
end

projects = Project.find_in_directory(root_directory)

warn 'Iterating on project updates'

projects.each do |p|
  begin
    update(p, apply_changes:)
  rescue => e
  project_logs << p
    warn "An error occurred while updating project: #{e.message}"
  end
end

warn 'Completed iterating on project updates'

unless ENV['APPLY_CHANGES']
  warn 'APPLY_CHANGES environment variable is unset or has an invalid value, exiting instead of making a new PR'
  exit 0
end

clean = true

branch_name = Time.now.strftime('updated-stats-%Y%m%d')

setup_git_config(root_directory)
  warn 'before setting git config changes'
  set_git_config_username
  set_git_config_useremail

  warn 'after setting git config changes'

  set_git_remote_url(token, current_repo)
  # Git now warns when the remote URL is changed, and we need to opt-in for continuing to work with this repository
  add_safe_directory

  warn 'after changing git remote url'

  check_clean_state

  warn 'after git diff'

    # Add, commit, and push
  unless clean
    system("git checkout -b #{branch_name}")
    warn 'after git checkout'
    system('git add _data/projects/')
    warn 'after git add'
    system("git commit -m 'regenerated project stats'")
    warn 'after git commit'
    system("git push origin #{branch_name}")
    warn 'after git push'
  end
end

unless clean
  body = 'This PR updates the project stats for all repositories that use a single label in a single GitHub repository. It includes regenerated project statistics and updated label links based on the latest data from the GitHub API.'

  client.create_pull_request(current_repo, 'gh-pages', branch_name, 'Updated project stats', body) if found_pr.nil?
end

finish = Time.now
delta = finish - start

warn "Operation took #{delta}s"

exit 0
