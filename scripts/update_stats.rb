# frozen_string_literal: true

require 'safe_yaml/load'
require 'uri'
require 'octokit'
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
    warn 'This script is currently rate-limited by the GitHub API'
    warn 'Marking as inconclusive to indicate that no further work will be done here'
    exit 0
  end

  if result[:reason] == 'repository-missing'
    warn "The GitHub repository '#{project.github_owner_name_pair}' cannot be found. Please confirm the location of the project."
    return
  end

  if result[:reason] == 'issues-disabled'
    warn "The GitHub repository '#{project.github_owner_name_pair}' has issues disabled, and should be cleaned up with the next deprecation run."
    return
  end

  if result[:reason] == 'error'
    warn "An error occurred: #{result[:error]}"
    return
  end

  obj = project.read_yaml
  label = obj['upforgrabs']['name']

  if result[:reason] == 'missing'
    warn "The label '#{label}' for GitHub repository '#{project.github_owner_name_pair}' could not be found. Please ensure this points to a valid label used in the project."
    return
  end

  link = obj['upforgrabs']['link']

  url = result[:url]

  link_needs_rewriting = link != url && link.include?('/labels/')

  unless apply_changes
    warn "The label link for '#{label}' in project '#{project.relative_path}' is out of sync with what is found in the 'upforgrabs' element. Ensure this is updated to '#{url}'" if link_needs_rewriting
    return
  end

  obj.store('upforgrabs', 'name' => label, 'link' => url) if link_needs_rewriting

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

current_repo = ENV.fetch('GITHUB_REPOSITORY', '').split('/').last

warn "Inspecting projects files for '#{current_repo}'"

if current_repo.nil?
  warn 'GITHUB_REPOSITORY environment variable is not set'
  exit 1
end
start = Time.now

root_directory = Dir.pwd
apply_changes = ENV['APPLY_CHANGES'] == 'true'
token = ENV['GITHUB_TOKEN']

client = Octokit::Client.new(bearer_token: token)
prs = client.pulls current_repo

if projects.empty?
  warn 'No projects were found in the root directory'
  exit 0
end
found_pr = prs.find { |pr| pr.title == 'Updated project stats' && pr.user.login == 'shiftbot' && pr.state == 'open' }

if found_pr
  warn "There is a current PR open to update stats ##{found_pr.number} - review and merge that before we go again"
  exit 0
end

projects = Project.find_in_directory(root_directory)

warn 'Iterating on project updates'

projects.each do |p|
end
if projects.empty?
  warn 'No projects were found in the root directory'
  exit 0
end
  begin
    puts 'Updating project: #{p.relative_path}'
begin
  update(p, apply_changes: apply_changes)
  puts 'Updated project: #{p.relative_path}'
rescue => e
  warn "An error occurred while updating project '#{p.relative_path}': #{e.message}"
end
  rescue => e
    warn "An error occurred while updating project: #{e.message}"
  end
end

warn 'Completed iterating on project updates'

unless apply_changes
  warn 'APPLY_CHANGES environment variable unset, exiting instead of making a new PR'
  exit 0
end

clean = true

# Add appropriate logging statements

branch_name = Time.now.strftime('updated-stats-%Y%m%d')

Dir.chdir(root_directory) do
  puts 'Before setting git config changes'
  system('git config --global user.name "shiftbot"')
  system('git config --global user.email "12331315+shiftbot@users.noreply.github.com"')

  puts 'After setting git config changes'

  system("git remote set-url origin 'https://x-access-token:#{token}@github.com/#{current_repo}.git'")
  # Git now warns when the remote URL is changed, and we need to opt-in for continuing to work with this repository
  system("git config --global --add safe.directory #{Dir.pwd}")

  puts 'After changing git remote url'

  clean = system('git diff --quiet > /dev/null')

changes_exist = !clean

  puts 'After git diff'

  unless clean
    system("git checkout -b #{branch_name}")
    puts 'After git checkout'
    system('git add _data/projects/')
    puts 'After git add'
    system("git commit -m 'regenerated project stats'")
    puts 'After git commit'
    system("git push origin #{branch_name}")
    puts 'After git push'
  end
end

unless clean
  body = 'This PR regenerates the stats for all repositories that use a single label in a single GitHub repository'

  client.create_pull_request(current_repo, 'gh-pages', branch_name, 'Updated project stats', body) if found_pr.nil?
end

finish = Time.now
delta = finish - start

warn "Operation took #{delta}s"

exit 0
