#!/bin/bash

# Define the directory
dir=$(pwd)

# Check if the directory exists
if [ -d "$dir" ]; then
  cd "$dir"
else
  echo "Directory $dir does not exist."
  exit 1
fi

# Get the current date
riqi=$(date)

# Check if there are any changes
if [ -n "$(git status --porcelain)" ]; then
  # Add all changes
  git add .
  if [ $? -eq 0 ]; then
    echo "Changes added successfully."
  else
    echo "Failed to add changes."
    exit 1
  fi

  # Get the latest changed filename
  filename=$(git diff --name-only HEAD | tail -n 1)

  # Define a commit message
  commit_message="This is for my iPhone git push or pull at $riqi. Last changed file: $filename"

  # Commit the changes
  git commit -m "$commit_message"
  if [ $? -eq 0 ]; then
    echo "Changes committed successfully."
  else
    echo "Failed to commit changes."
    exit 1
  fi

  # Push the changes
  git push
  if [ $? -eq 0 ]; then
    echo "Changes pushed successfully."
  else
    echo "Failed to push changes."
    exit 1
  fi
else
  echo "No changes to commit."
fi%
