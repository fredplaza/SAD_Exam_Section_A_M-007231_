# ScholarTrack MVP

Browser-based scholarship-renewal system for the SAD laboratory examination. It uses PHP sessions and SQLite; no external service, password, or service-role key is required.

## Run locally

From this directory, run:

```sh
/Applications/XAMPP/xamppfiles/bin/php -S localhost:8000
```

Open `http://localhost:8000`. The database is generated and seeded on the first request.

Test accounts:

- Staff: `staff@demo.edu` / `Staff123!`
- Scholar: `a01@demo.edu` / `Scholar123!`

The included test records use AY `2026-2027`, Semester `1`. The app applies Manila deadline rules stored on the selected program record.

## Submission notes

The application intentionally does not connect to Registrar systems, modify official grades, release payments, or implement policy exceptions/appeals. Seeded values are synthetic test data.
