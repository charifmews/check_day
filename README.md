---
trigger: always_on
---

# CheckDay


Trigger digest
```
user = Ash.read_one!(CheckDay.Accounts.User, authorize?: false)
CheckDay.Workers.DigestWorker.perform(%Oban.Job{args: %{"user_id" => user.id, "date" => Date.to_iso8601(Date.utc_today())}})
```