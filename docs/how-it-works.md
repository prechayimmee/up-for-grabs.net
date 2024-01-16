# How It Works

Rather than explaining the entirety of the stack, this document will explain
the key parts of the Up-for-Grabs site and project.

## Displaying projects

The main site is a Jekyll repositorysitory hosted on GitHub Pages, but it leverages
some neat features of Jekyll along the way.

- We use [Data files](https://jekyllrb.com/docs/datafiles/) to represent the
  projects listed on the site - one file per project, found under
  `_data/projects`
- We convert this file to JSON inside [`javascripts/projects.json`](../javascripts/projects.json)
  when the site is built using `jekyll`
- The [`projectLoader`](../javascripts/projectLoader.js) module runs when the
  page is loaded, retrieving these projects and making them available for the
  site
- The [`projectsService`](../javascripts/projectsService.js) module handles
  the rest of the work to sort and search the projects
- The [`main`](../javascripts/main.js) module handles the rest of the work to
  render the list of projects and provide the UI for filtering based on label
  or tags

## Project Infrastructure

We've settled on some infrastructure choices that mean we don't need to worry
about managing our own servers, and can save time on the manual work that comes
with a project of this size:

- [GitHub Workflows](https://github.com/features/actions) is used to automate various tasks such as updating project statistics, checking project activity, and more. It runs every time you build or create a pull request to ensure the project is ready to be deployed.
- [Netlify](https://www.netlify.com/) hooks check every pull request to test the deployment and give reviewers a preview of the changes, so they don't have to download and verify the changes locally.
- When you push a commit to the `gh-pages` branch, a deployment is started to publish the latest code to [GitHub Pages](https://pages.github.com/), which
  hosts the site
- A GitHub Action, using the 'update_stats.rb' script, runs weekly to scan the project list and remove any projects that are no longer active by checking if they are still accessible via the GitHub API. This saves us from having to manually review projects for inactivity.
- Every day, a GitHub Action, using the 'review_changes.rb' script, checks each project and updates the data files with the latest commit statistics. This ensures that the statistics are always up-to-date when the site is published, so visitors can easily see which projects have available issues.
