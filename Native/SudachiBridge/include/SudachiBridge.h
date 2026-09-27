#ifndef JP_SUDACHI_BRIDGE_H
#define JP_SUDACHI_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif
// All returned strings are owned by the caller and must be released exactly once.
char *jp_sudachi_analyze(const char *config_path, const char *resource_path, const char *dictionary_path, const char *text);
// split_mode: 0=A, 1=B, 2=C. Legacy entry point defaults to C.
char *jp_sudachi_analyze_with_mode(const char *config_path, const char *resource_path, const char *dictionary_path, const char *text, int split_mode);
void jp_sudachi_free(char *text);
#ifdef __cplusplus
}
#endif
#endif
