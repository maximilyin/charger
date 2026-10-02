ExUnit.start()

# Boot queues a refresh. Wait for it so the suite only reads the ETS cache.
Charger.Prices.Cache.refresh_now()
Charger.Chargers.Cache.refresh_now()
