# Contributing Process

This guide loosely outlines the process of contributing to the project. It is a simple guide, and not intended to be a strict process. If you have any questions, please ask us wherever we're hanging out. We're happy to help.

## Getting Started

First, you'll need to fork the project. This will create a copy of the project in your own GitHub account. You'll need to clone this fork to your local machine. You can do this by running the following command:

```bash
git clone https://github.com/Satellite-im/Uplink.git
```

## Creating a Branch

Once you've cloned the project, you'll need to create a branch. This will allow you to make changes to the project without affecting the main branch. You can do this by running the following command:

```bash
git checkout -b <branch-name>
```

## Making Changes

Once you've created a branch, you can start making changes to the project. You can do this by editing the files in your local copy of the project. Once you've made your changes, you'll need to commit them. You can do this by running the following command:

```bash
git commit -m "<commit-message>"
```

It is best to follow our commit message guidelines. This will help us to understand what changes you've made. We use features, fixes, and chores to categorize our commits. You can read more about this in our [commit message guidelines](docs/toodo.md).

## Pushing Changes

Once you've committed your changes, you'll need to push them to your fork. You can do this by running the following command:

```bash
git push origin <branch-name>
```

## Creating a Pull Request

Once you've pushed your changes to your fork, you'll need to create a pull request. This will allow us to review your changes and merge them into the `dev` branch. You can do this by navigating to your fork on GitHub and clicking the "New pull request" button. You'll then need to select the branch that you want to merge into the main branch. You can then click the "Create pull request" button.

## Reviewing Pull Requests

Once you've created a pull request, we'll review it. We'll either merge it into the `dev` branch or request changes. If we request changes, you'll need to make the changes and push them to your fork. Once you've pushed the changes, we'll review them again. 

If a reviewer has been requested or assigned to a pull request, they will be responsible for reviewing it. If a reviewer has not been requested or assigned, the pull request will not be merged until the code has been reviewed by a maintainer.

Ideally two (`2`) maintainers will review a pull request before it is merged. If a pull request is urgent, it may be merged without two reviews. If a maintainer adds themselves as a reviewer we should **wait to merge the pull request until they have reviewed it**.

## Merging Pull Requests

Once a developer has reviewed the pull request our QA team will test the changes. If the changes pass QA, the pull request will be merged into the `dev` branch. If the changes fail QA, the pull request will have comments about how to replicate the issues. In some cases a new issue may be opened but in most cases we will request that all features pass through the QA team before being merged. 

If QA requests changes at least one (`1`) maintainer must review the changes before the pull request is merged. If QA requests changes and no maintainers are available, the pull request will not be merged until a maintainer has reviewed the changes.

## Deleting Branches

Once a pull request has been merged, you'll need to delete the branch. You can do this by navigating to your fork on GitHub and clicking the "Delete branch" button. You'll then need to confirm that you want to delete the branch.

