# Work out of the request

Some of Storehouse's work runs after the request that asked for it:

* a file's analysis (`Storehouse.analyze_later/3`, and
  `Storehouse.Ecto`'s `analyze:`);
* deletions of files a record no longer has (`Storehouse.delete_later/2`,
  `Storehouse.Ecto.update/3`);
* a mirror's copies (`Storehouse.Mirror`).

Each is a job (`Storehouse.Job`): a worker and its arguments, which JSON
holds. A runner (`Storehouse.Runner`) keeps the jobs, runs them, and tries
them again when a store fails. One runner does all of Storehouse's work,
and another takes its place with no other change.

## Oban

When the app runs Oban (an instance named `Oban`), Storehouse's jobs are
Oban jobs (`Storehouse.Runner.Oban`): kept in the database, so a deploy in
the middle of them loses nothing, and retried with Oban's backoff.

Give them the queue you want them on, and the instance, if it is not
named `Oban`:

```elixir
# config/config.exs
config :storehouse, Storehouse.Runner.Oban, queue: :media, name: MyApp.Oban

config :my_app, Oban, queues: [default: 10, media: 4]
```

With no `:queue`, they go on `:storehouse`. When the instance runs no
such queue, Storehouse says so once in the log: its jobs would wait.

## Without Oban

`Storehouse.Runner.Memory` runs them in a process of the app's, with
retries and backoff:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Storehouse.Runner.Memory, max_concurrency: 8},
  MyAppWeb.Endpoint
]
```

Its jobs live in memory: those not done when the app stops are not done.
Without its process, each job runs at once, in the caller.

## Choosing one

```elixir
# For all of Storehouse's work.
config :storehouse, runner: Storehouse.Runner.Memory

# For one call.
Storehouse.analyze_later(file, steps, then: {…}, runner: {Storehouse.Runner.Oban, queue: :slow})

# For a mirror's copies.
use Storehouse.Mirror, primary: …, mirrors: […], runner: Storehouse.Runner.Oban
```

## Your own

Another job system, a workflow engine, a queue of your platform: a
runner is one callback, `c:Storehouse.Runner.enqueue/2`, which keeps the
job (`Storehouse.Job.to_map/1` gives it as JSON holds it), and then, where
it runs, `Storehouse.Job.run/1`, tried until it gives `:ok`, up to the
job's `:max_attempts`, then `Storehouse.Job.discarded/3`.
`Storehouse.Runner` has an example.

## Telemetry

Each run of a job is a span, `[:storehouse, :job, :start | :stop |
:exception]`, with its `:worker`; a job given up is
`[:storehouse, :job, :discarded]`, with its `:attempts`, the `:job` and
the `:reason`: an alert for a mirror left behind.
