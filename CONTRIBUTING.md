# **How to Contribute to DevOps**

Thank you for taking the time to contribute!

The following guidelines are for contributing to the devops repository hosted on GitHub. These are intended as guidelines rather than strict rules. Please use your discretion, and don't hesitate to suggest changes to this document by submitting a pull request.

> ### ⚠️ **Do not fork. Work on a branch in the Hack for LA repository itself.**
>
> Every DevOps Community of Practice repository is contributed to the same way: you are given write access, you clone the Hack for LA repository directly, and you push a branch to it. You do **not** create a copy of the repository under your own GitHub account.
>
> For [**incubator**](https://github.com/hackforla/incubator), this is not just a convention — **a pull request opened from a fork cannot be accepted.** See [Do not fork the repository](#do-not-fork-the-repository) below for what breaks and why.

**This guide assumes that you have finished the onboarding process, which involves joining the Hack for LA Slack, GitHub, and Google Drive. If you haven't completed onboarding yet, please visit the [Getting Started Page](https://www.hackforla.org/getting-started).**

**The team recommends using [VS Code](https://code.visualstudio.com/download) as the preferred text editor for working on code, but feel free to utilize a text editor of your preference.**

**If you have any additional questions about your contribution process, please feel free to reach out to the team in the [#ops](https://hackforla.slack.com/archives/CV7QGL66B) Slack channel.**

**For more about how the DevOps CoP works — who the leads are, how we meet, and how permissions are handled — see the [DevOps wiki](https://github.com/hackforla/devops/wiki).**
<br><br>

## **Table of Contents**

- [**How to Contribute to DevOps**](#how-to-contribute-to-devops)
  - [**Table of Contents**](#table-of-contents)
  - [**Do not fork the repository**](#do-not-fork-the-repository)
    - [**Why incubator pull requests from a fork cannot be accepted**](#why-incubator-pull-requests-from-a-fork-cannot-be-accepted)
    - [**Getting write access**](#getting-write-access)
  - [**Setting up the local development environment**](#setting-up-the-local-development-environment)
  - [**Clone (Create) a copy on your computer**](#clone-create-a-copy-on-your-computer)
    - [Clone repo (1): Create `hackforla` folder](#clone-repo-1-create-hackforla-folder)
    - [Clone repo (2): Verify `origin` remote url](#clone-repo-2-verify-origin-remote-url)
  - [**Working on an issue**](#working-on-an-issue)
    - [**Working on an issue (1): Verify current branch is `master`**](#working-on-an-issue-1-verify-current-branch-is-master)
    - [**Working on an issue (2): Create a new branch where you will work on your issue**](#working-on-an-issue-2-create-a-new-branch-where-you-will-work-on-your-issue)
    - [Branch name convention](#branch-name-convention)
    - [**Working on an issue (3): Prepare your changes to push to the repository**](#working-on-an-issue-3-prepare-your-changes-to-push-to-the-repository)
    - [**Working on an issue (4): Pulling the latest changes before you push**](#working-on-an-issue-4-pulling-the-latest-changes-before-you-push)
  - [**Making a pull request**](#making-a-pull-request)

## **Do not fork the repository**

Read this before you clone anything. Getting it wrong means redoing your setup, and on one repository it means your pull request cannot be merged at all.

You contribute to a DevOps CoP repository by pushing a branch **to that repository**, not to a fork:

- ✅ `git clone https://github.com/hackforla/devops.git` — then branch, commit, push, and open the pull request from your branch.
- ❌ Clicking **Fork**, cloning `https://github.com/<your_GitHub_user_name>/devops.git`, and opening a pull request from your copy.

This applies to all three DevOps CoP repositories — [devops](https://github.com/hackforla/devops), [devops-security](https://github.com/hackforla/devops-security), and [incubator](https://github.com/hackforla/incubator).

### **Why incubator pull requests from a fork cannot be accepted**

On [incubator](https://github.com/hackforla/incubator) (and [devops-security](https://github.com/hackforla/devops-security)), every pull request automatically runs `terraform plan`, and that workflow has to authenticate to AWS to do it. **GitHub deliberately withholds repository secrets and the OIDC token from a workflow run triggered by a pull request that comes from a fork**, and it downgrades the workflow's token to read-only.

The result is that a pull request opened from a fork:

- cannot run the Terraform plan, and
- cannot post the plan back as a comment on the pull request.

That plan comment is the *only* thing a reviewer has to look at — it is how we see what your change would actually do to live infrastructure before it is applied. Without it there is nothing to review, so the pull request cannot be approved or merged. This is a limitation of how GitHub protects secrets, not something a reviewer can override or re-run for you.

### **Getting write access**

Because you are pushing branches to the Hack for LA repository, you need write access to it. If `git push` is rejected with a permission error, that is what is missing — ask a [DevOps CoP Lead](https://github.com/hackforla/devops/wiki/Community#devops-community-of-practice-cop-leads) in the [#ops](https://hackforla.slack.com/archives/CV7QGL66B) Slack channel.

<sub>[Back to Table of Contents](#table-of-contents)</sub>

## **Setting up the local development environment**

### **Clone (Create) a copy on your computer**

Before creating a copy to your local machine, you must have Git installed. You can find instructions for installing Git for your operating system [**here**](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git).

The following steps will clone (create) a local copy of the Hack for LA repository on your computer.

#### Clone repo (1): Create `hackforla` folder

Create a new folder on your computer that will contain `hackforla` projects.

Navigate to the location where you want to create a new folder for your `hackforla` projects using your command line interface(Terminal, Git Bash, Powershell). Create a new folder on your computer to hold these projects. Then, navigate into the newly created folder.

For example:

```bash
mkdir hackforla
cd hackforla
```

and run the following command:

```bash
git clone https://github.com/hackforla/devops.git
```

You should now have a new folder in your `hackforla` folder called `devops`. Verify this by changing into the new directory:

```bash
cd devops
```

#### Clone repo (2): Verify `origin` remote url

Verify that your local cloned repository is pointing to the correct `origin` URL — the Hack for LA repository, **not** a copy under your own account:

```bash
git remote -v
```

You should see `fetch` and `push` URLs that both point at `https://github.com/hackforla/devops.git`:

```bash
origin  https://github.com/hackforla/devops.git (fetch)
origin  https://github.com/hackforla/devops.git (push)
```

If instead you see a URL with your own GitHub username in it, you cloned a fork. Point `origin` back at the Hack for LA repository:

```bash
git remote set-url origin https://github.com/hackforla/devops.git
```

There is no `upstream` remote to add. Because `origin` *is* the Hack for LA repository, you pull from and push to the same place, and there is nothing to keep in sync.

<sub>[Back to Table of Contents](#table-of-contents)</sub>

### **Working on an issue**

For each issue you address, create a new branch. Working on topic branches keeps the default branch (named `master`) untouched and keeps your work separate from everyone else's.

#### **Working on an issue (1): Verify current branch is `master`**

first make sure you are on the master branch.

```bash
git checkout master
```

Update your master branch with the latest changes

```bash
git pull
```

<sub>[Back to Table of Contents](#table-of-contents)</sub>

#### **Working on an issue (2): Create a new branch where you will work on your issue**

Using `git checkout -b` command to create a new branch and immediately switch into it.

#### Branch name convention

Choose a branch name that:

- relates to the issue (No spaces!)
- includes the issue number

For example, if you create a new issue branch for [Add a CONTRIBUTING.md to the DevOps repo #120](https://github.com/hackforla/devops/issues/120):

```bash
git checkout -b add-contributing-md-120
```

Here `add-contributing-md-120` is your branch name

**Note:** The format should resemble the scheme above, with words that briefly describe the issue in a way that is understandable at a glance to someone unfamiliar with the problem. The issue number should be included at the end.

**Note:** Git uses spaces as delimiters in various commands, so branch names cannot contain spaces.

#### **Working on an issue (3): Prepare your changes to push to the repository**

##### **i. Prepare repo changes (1): Use the `git add` command to stage your changes.**

This command prepares your changes for the next commit. You can stage files individually by specifying their filenames.

Run this command if you want to **add changes from a specific file(s) to your commit record**:

```bash
git add “filename.ext”
```

Run this command if you want to **add all changes to all file(s) to your commit record**:

```bash
git add .
```

##### **ii. Prepare repos changes (2): Use the `git status` command to see what files are staged.**

This command display a list of files that have been staged for the next commit. These files will be included in the commit when you run `git commit`. Ensure that all staged changes are relevant to the current task if you accidentally staged unrelated changes, you can unstage them before committing by following the instructions provided in the output of your `git status` command.

```bash
git status
```

##### **iii. Prepare repos changes (3): Use the `git commit` command**

This command saves your changes and prepares them for pushing to your repository. You can use the `-m` flag to add a message to your commit. The message should be a brief description of the issue you are addressing. It is important to make the message clear and understandable to others who may read it. Avoid being overly cryptic in your message.

To commit your changes with a message, run:

```bash
git commit -m “your commit message”
```

#### **Working on an issue (4): Pulling the latest changes before you push**

**IMPORTANT:** Before you push your local commits, bring your branch up to date with the `master` branch of the repository, so that you are not opening a pull request against stale code.

```bash
git pull origin master
```

After committing your changes locally, use the command below to push your branch to the Hack for LA repository, making it available for a pull request:

```bash
git push --set-upstream origin add-contributing-md-120
```

<sub>[Back to Table of Contents](#table-of-contents)</sub>

### **Making a pull request**

Open the pull request from your branch on the Hack for LA repository into `master`.

##### **i. Complete pull request (1): Update pull request title**

The default title will be your branch name. Please modify it as you see fit.

##### **ii. Complete pull request (2): Explain the changes you made, then explain why these changes were needed**

In description area, describe the changes you made to complete the action items in your issue and explain the reasons behind those changes.

<sub>[Back to Table of Contents](#table-of-contents)</sub>
