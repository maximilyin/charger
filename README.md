# Charger

A desktop catalog of fuel stations and EV chargers in Spain. Station data on the page comes from a local cache. The map is drawn with MapLibre from OpenFreeMap vector tiles.

Two background processes refresh the data on their own.

- **Fuel.** Once an hour the app fetches the ministry's open JSON: prices for 95, 98, diesel B7, and premium diesel B7+, plus the address, opening hours, and coordinates. Source: [EstacionesTerrestres](https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/).
- **Chargers.** The app collects the Reve catalog (the API allows about five requests an hour) into `priv/cache/reve-locations.json`: first the operator list, then the locations of each operator, then the connector tariffs into the same file. A station whose id is already stored is not written again. Until the location list is complete, the catalog shows the public RIPREE CSV, fetched once a day; after that it shows Reve stations. The table shows power, operator, address, opening hours, and a map link. Neither source gives live status (free, occupied, or out of service) in the station list.

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

## Run in Docker

The image needs only Docker; Elixir is not required on the host. The `Dockerfile` builds a production release in one stage and runs it in a smaller one.

```bash
docker build -t charger .

docker run --rm -p 4000:4000 \
  -e SECRET_KEY_BASE="<64+ random characters>" \
  -e PHX_HOST=localhost \
  -e REVE_API_KEY="<your Reve key>" \
  -v "$PWD/priv/cache:/data" \
  charger
```

The catalog is at [http://localhost:4000](http://localhost:4000).

| Variable | Required | Meaning |
| --- | --- | --- |
| `SECRET_KEY_BASE` | yes | Signs cookies and LiveView sessions. Generate it once with `mix phx.gen.secret` or `openssl rand -base64 48` and keep it; a new value logs out open sessions. |
| `PHX_HOST` | yes | Host the site is opened from. If it does not match, LiveView refuses the WebSocket connection. |
| `REVE_API_KEY` | no | Key for the Reve API. Without it the collector logs `missing api key` and gathers nothing new; the catalog shows the Reve stations already in the cache file, or RIPREE if there are none. |
| `PORT` | no | Port inside the container, `4000` by default. |
| `CACHE_DIR` | no | Directory for the cache files, `/data` in the image. |

The cache files are written to `/data`. The `-v "$PWD/priv/cache:/data"` mount keeps them on the host, so the container continues the Reve collection where the local app stopped and the data survives a container restart. Do not run the container and `mix phx.server` on the same folder at once: both would rewrite the same files.

The Reve key and `config/dev.secret.exs` are never copied into the image (see `.dockerignore`); pass the key only with `-e`.

## Checks

```bash
mix test
mix precommit
```

`mix precommit` compiles with warnings as errors, checks the lock file for unused dependencies, formats the code, and runs the tests.
