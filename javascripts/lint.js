// javascripts/lint.js

const eslint = require('eslint');

function runEslint() {
  const cli = new eslint.CLIEngine();
  const report = cli.executeOnFiles(['javascripts/*.js', 'tests/**/*.js']);
  const formatter = cli.getFormatter();

  return formatter(report.results);
}

module.exports = {
  runEslint,
};
