# ken
Catalog books and papers related to your research interests.

## Design

`ken` consists of:
1. A database schema that can store information about publications (books, papers, videos, etc.), your own notes
about those publications, and model relationships between those publications (citations, references, etc.).
2. A CLI that makes it easy to manage the contents of `ken` databases following the above schema.

The `ken` CLI is designed to be easy for both humans and AI agents to use. Especially for agents, it includes a
`ken skill` subcommand which generates skills for use in agentic frameworks such as Claude Code, Cursor, and Codex.

For databases, `ken` uses SQLite. This allows users to maintain databases on their filesystems and share information
with themselves or with others by simply copying the files. `ken` acknowledges the sharing of references and notes
as a critical use case. It makes it easy to export references into a fresh database and merge databases together.

Each version of `ken` comes with a schema migration that can be applied to any `ken` DB from an earlier release
to make it compatible with the latest specification. We make the guarantee that these migrations will never fail.

### Database schema

#### Publication kinds

`ken` declares the kinds of publications it recognizes (e.g. `book`, `paper`, `conference_proceeding`, `video`) as
part of the database.

This information is in the `publication_kinds` table, which the following columns:
1. `name`: string primary key, e.g. `"book"`, `"paper"`.
2. `description`: a string column which holds descriptions about this kind of publication. This column should describe how publications
of a given kind are keyed.

`ken` ships with a default list of `publication_kinds`, but users may add their own kinds if they wish to. Custom
`publication_kinds` could introduce merge conflicts in `ken` databases.

#### Publications

The `publications` table actually holds publications that users have inserted into the `ken` database. This table has
the following columns:
1. `id`: This is a UUID assigned to the publication randomly and uniquely upon insertion into the database, and serves as the primary key for the `publications` table.
2. `kind`: This is a foreign key into the `publication_kinds` table. Deletion of a row from `publication_kinds` is restricted if any publications reference that kind.
3. `title`: An optional string column for the human-readable title of the publication.
4. `key`: This is a key associated with the `kind` of the publication which identifies how to look it up externally. For example, this
could be a DOI reference for papers, or an ISBN for books. The `kind` should declare in its description (in the `publication_kinds` table) how keys should
be parsed.
5. `created_at`: Timestamp (ISO 8601, UTC) recording when this row was inserted.
6. `updated_at`: Timestamp (ISO 8601, UTC) recording when this row was last modified.

#### Notes

The `notes` table stores the textual contents of user notes. Corresponding to this table, there is a `note` kind in the `publication_kinds` table. By default,
notes are keyed by their ids in the `notes` table.

The columns in this table are:
1. `id`: A UUID assigned to each note at its time of creation.
2. `content`: The actual content of the note.
3. `created_at`: Timestamp (ISO 8601, UTC) recording when this note was created.
4. `updated_at`: Timestamp (ISO 8601, UTC) recording when this note was last modified.

We could alternatively conceive of notes as being stored in separate files on the filesystem, but then a merge of databases would also require the notes to
be resolved separately but atomically with databases being merged. Storing notes like this directly in the `ken` database makes a database self-contained and
allows for atomic merges (at least as far as the canonical kinds are concerned).

#### Relationship kinds

The `relationship_kinds` table defines the types of relationships that can exist between publications. It has the following columns:
1. `name`: string primary key, e.g. `"cites"`, `"develops"`, `"duplicates"`, `"derives from"`.
2. `description`: string column which describes what the relationship kind represents, and how to interpret it.

Note that relationships in `ken` are directed by default. Each relationship has a `subject` and an `object`, as we will see below.

#### Relationships

The `relationships` table represents relationships between publications. It has the following columns:
1. `id`: A UUID assigned to each row when it is first created. This is the primary key for a relationship.
2. `kind`: Foreign key into `relationship_kinds.name`. If the row is deleted from `relationship_kinds`, this row gets deleted.
3. `subject`: Foreign key into `publications.id`. If the row is deleted from `publications`, this row gets deleted.
4. `object`: Foreign key into `publications.id`. If the row is deleted from `publications`, this row gets deleted.
5. `created_at`: Timestamp (ISO 8601, UTC) recording when this relationship was created.
6. `updated_at`: Timestamp (ISO 8601, UTC) recording when this relationship was last modified.

Note that each relationship by default is a predicate between a subject publication and an object publication. This implies that the
implied graph over publications is directed. This does not preclude a user making undirected edges (i.e. `relationship_kinds` rows).
They should simply declare as such in the corresponding `relationship_kinds.description`.

#### The importance of descriptions

Note how important the descriptions are in the `publication_kinds` and `relationship_kinds` tables. This is because `ken` is built to be easy
for humans and AI to use. The descriptions achieve this by:
1. Telling humans who are looking at a `ken` database what kind of semantics to expect of their related queries and how to perform external lookups for
data.
2. Providing a specification for AI operating over a `ken` database for how to parse various artifacts from that database, the semantics that it should
follow when querying the database, and how to perform external lookups.

The more formal and comprehensive the descriptions, the better.
