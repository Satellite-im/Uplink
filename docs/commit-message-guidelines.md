# Commit Message Guidelines

We follow a set of commit message guidelines to maintain clarity and organization in our version control history. 

Each commit message should follow the format:

`<type>(<scope>): <description>`

Here are the types of commits we use and their explanations:

| Type      | Description                                                | Example                                    |
|-----------|------------------------------------------------------------|--------------------------------------------|
| add       | Adding a new feature, file, or functionality to the project. | `add(auth): Implement user registration feature` |
| update    | Making updates or improvements to existing code or functionality. | `update(styles): Update the styling of the login page` |
| task      | Completing a specific task or goal, typically not directly related to features or fixes. | `task(docs): Create project documentation` |
| chore     | General maintenance tasks, such as refactoring, code cleanup, or build-related changes. | `chore(build): Optimize build process` |
| feat      | Introducing new features or significant enhancements. | `feat(chat): Add real-time chat functionality` |
| fix       | Addressing and fixing bugs or issues in the codebase. | `fix(chat): Resolve chat message not sending` |
| refactor  | Making code improvements without changing its behavior or introducing new features. | `refactor(api): Refactor API endpoints for clarity` |

Format and Example:
- `<type>`: The type of the commit based on the defined keywords.
- `<scope>` (optional): Additional context specifying the codebase section affected, enclosed in parentheses.
- `<description>`: A brief and concise summary of the changes made.

These guidelines help us create a meaningful and structured commit history, making it easier to track changes, generate changelogs, and understand the purpose of each commit.
