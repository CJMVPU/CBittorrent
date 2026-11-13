#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CBTEngine CBTEngine;

// All strings are UTF-8. Returned strings and errors belong to the caller.
// Calls on one engine are serialized internally. Creation requires an isolated
// application profile directory, not a qBittorrent configuration directory.
CBTEngine *cbt_engine_create(const char *profilePath, char **error);
// Apply network/privacy settings before the session starts or tasks are restored.
CBTEngine *cbt_engine_create_configured(const char *profilePath, const char *settingsJSON, char **error);
void cbt_engine_destroy(CBTEngine *engine);
// Returns null on snapshot failure, preserving the caller's previous display.
char *cbt_engine_snapshot_json(CBTEngine *engine);
int cbt_engine_add(CBTEngine *engine, const char *source, const char *savePath, int paused, char **error);
int cbt_engine_pause(CBTEngine *engine, const char *torrentID, char **error);
int cbt_engine_resume(CBTEngine *engine, const char *torrentID, char **error);
int cbt_engine_remove(CBTEngine *engine, const char *torrentID, int deleteFiles, char **error);
int cbt_engine_set_limits(CBTEngine *engine, int downloadBytesPerSecond, int uploadBytesPerSecond, char **error);
// Apply a partial JSON object after validating all supplied engine fields.
int cbt_engine_apply_settings(CBTEngine *engine, const char *json, char **error);
// Appends the configured default trackers to existing tasks; reports changed tasks.
int cbt_engine_apply_default_trackers(CBTEngine *engine, int *changedCount, char **error);
// Includes configured values and effective libtorrent settings for diagnostics/tests.
char *cbt_engine_settings_json(CBTEngine *engine);
int cbt_engine_set_file_priority(CBTEngine *engine, const char *torrentID, int fileIndex, int priority, char **error);
int cbt_engine_save(CBTEngine *engine, char **error);
int cbt_engine_connect_peer(CBTEngine *engine, const char *torrentID, const char *address, int port, char **error);
void cbt_string_free(char *string);

#ifdef __cplusplus
}
#endif
