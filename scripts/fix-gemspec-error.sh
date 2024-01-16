#!/bin/bash

# Remove the "gemspec" line from the Gemfile
sed -i '/gemspec/d' Gemfile
