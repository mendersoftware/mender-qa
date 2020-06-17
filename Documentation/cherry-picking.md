Cherry-picking
==============

When making bug fixes in any of the Mender components, it is important to
cherry-pick these to release branches, which are used by on-prem releases. The
general mantra you should always have in the back of your head is:

> Is this a bug fix, or a new feature? If it's a bug fix, it should be
> cherry-picked.

How to deal with cherry-picks
-----------------------------

There are two main ways to deal with cherry-picks.

### You are not sure if it should be cherry-picked, or don't know how

In this case, set the task you have worked on to "Merged", instead of
"Done". This will be picked up later, either during the sprint planning or
during the release process. If there is no task you can just create a
placeholder task and set that to "Merged".

### Do the cherry-pick yourself

If you can cherry-pick yourself, that's great, since it saves the release
managers extra work. Here are the steps:

1. Identify the highest numbered branch for the service that ends with `.x`, for
   example `2.0.x`.

2. Check out that branch:
   ```bash
   git checkout 2.0.x
   ```

3. Cherry-pick the commits you need with this command.
   ```bash
   git cherry-pick -x <COMMITS>
   ```
   The `-x` adds the original commit SHA to the message, which is not required,
   but which helps to identify commits later on if there are regressions.

4. Submit the branch to GitHub and make a pull request which targets the `.x`
   branch.
