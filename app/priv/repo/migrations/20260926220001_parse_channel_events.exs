defmodule KickTracker.Repo.Migrations.ParseChannelEvents do
  use Ecto.Migration

  # Hosts were stored as sent, with `other_channel` and `viewers` unknown,
  # until real ones showed their fields. This fills both from the stored
  # payloads and trims the payloads to what is read, as
  # `KickTracker.ChannelEvents.row/4` now does for new ones (the hosting
  # side carried the hosting channel's playback URL, its livestream and
  # pictures; the receiving side the host's free-text message). The same
  # rules in SQL: a figure that is missing or of another type stays NULL.
  # `dedup_key` is left alone: it was, and still is, hashed from the event
  # as sent. Data only, and running it twice changes nothing; old and new
  # code both work with it. Not reversible (the trimmed fields are gone on
  # purpose).
  def up, do: Enum.each(statements(), &execute/1)

  def down, do: :ok

  # Apart, so a test can run them against stored rows.
  @doc false
  def statements do
    [
      """
      UPDATE channel_events e SET
        other_channel = CASE WHEN jsonb_typeof(d->'host_username') = 'string'
                              AND d->>'host_username' <> '' THEN d->>'host_username' END,
        viewers = CASE WHEN jsonb_typeof(d->'number_viewers') = 'number'
                         AND d->>'number_viewers' ~ '^[0-9]+$'
                       THEN (d->>'number_viewers')::integer END,
        payload = jsonb_set(e.payload, '{data}', jsonb_build_object(
          'chatroom_id', d->'chatroom_id',
          'host_username', d->'host_username',
          'number_viewers', d->'number_viewers'))
      FROM (SELECT id, CASE WHEN jsonb_typeof(payload->'data') = 'object'
                            THEN payload->'data' ELSE '{}' END AS d
            FROM channel_events WHERE kind = 'hosted_by') s
      WHERE e.id = s.id
      """,
      """
      UPDATE channel_events e SET
        other_channel = coalesce(
          CASE WHEN jsonb_typeof(d->'slug') = 'string' AND d->>'slug' <> '' THEN d->>'slug' END,
          CASE WHEN jsonb_typeof(h->'slug') = 'string' AND h->>'slug' <> '' THEN h->>'slug' END),
        viewers = CASE WHEN jsonb_typeof(h->'viewers_count') = 'number'
                         AND h->>'viewers_count' ~ '^[0-9]+$'
                       THEN (h->>'viewers_count')::integer END,
        payload = jsonb_set(e.payload, '{data}', jsonb_build_object(
          'slug', d->'slug',
          'hosted', jsonb_build_object(
            'slug', h->'slug', 'username', h->'username', 'viewers_count', h->'viewers_count')))
      FROM (SELECT id, d, CASE WHEN jsonb_typeof(d->'hosted') = 'object'
                               THEN d->'hosted' ELSE '{}' END AS h
            FROM (SELECT id, CASE WHEN jsonb_typeof(payload->'data') = 'object'
                                  THEN payload->'data' ELSE '{}' END AS d
                  FROM channel_events WHERE kind = 'hosting') x) s
      WHERE e.id = s.id
      """
    ]
  end
end
