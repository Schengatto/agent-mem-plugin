"""DB package.

Per F1-04 le migrazioni sono interamente in raw SQL (vedi alembic/versions/).
Qui esportiamo solo un `MetaData` vuoto che Alembic userà come
`target_metadata`. I modelli ORM arriveranno quando servirà autogenerate
(probabilmente mai: lo schema è gestito a mano per controllo esplicito su
indici HNSW/GIN/partial e RLS policies).
"""

from sqlalchemy import MetaData

metadata = MetaData()
