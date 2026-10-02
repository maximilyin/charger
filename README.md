# Charger

A desktop catalog of fuel stations and EV chargers in Spain. Station data on the page comes from a local cache. The map is drawn with MapLibre from OpenFreeMap vector tiles.

Two background processes refresh the data on their own.

- **Fuel.** Once an hour the app fetches the ministry's open JSON: prices for 95, 98, diesel B7, and premium diesel B7+, plus the address, opening hours, and coordinates. Source: [EstacionesTerrestres](https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/).
- **Chargers.** Once a day the app fetches the public RIPREE CSV. Each row in the file is a connector; the catalog groups them into one installation. The table shows power, operator, address, opening hours, and a map link. That file has no live status (free, occupied, or out of service) and no price per kWh.

Both snapshots live in ETS. After each successful refresh the response is also written under `priv/cache/`. The first line of each file is the time of that update. If the API is down when the app starts, the file fills ETS, and the next refresh still tries the API. A failed refresh keeps the snapshot already in memory.

The page filters by province, municipality, fuel, and a text search. Filters are stored in the URL, so a link can be bookmarked. The interface is available in Ukrainian, English, and Spanish. The table lists the first 50 matching stations and can load further rows. The map shows every station that matches the filter, with its price. You can also sort stations near you.

The same fuel cache is available as JSON: `GET /api/stations`.

## Requirements

Elixir 1.18 and OTP 27. The build tool is Mix. Dependencies are declared in `mix.exs`; the locked versions are in `mix.lock`.

## Run

```bash
mix setup
mix phx.server
```

`mix setup` installs dependencies and builds the CSS and JavaScript. The catalog is at [http://localhost:4000](http://localhost:4000).

If Elixir is installed under `~/.elixir-install` rather than on `PATH`:

```bash
export PATH="$HOME/.elixir-install/installs/otp/27.3.4/bin:$HOME/.elixir-install/installs/elixir/1.18.4-otp-27/bin:$PATH"
```

## Checks

```bash
mix test
mix precommit
```

`mix precommit` compiles with warnings as errors, checks the lock file for unused dependencies, formats the code, and runs the tests.
