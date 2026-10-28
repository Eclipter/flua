#import <Foundation/Foundation.h>
BOOL FSConfigureConnection(NSXPCConnection *connection);
#ifdef FS_SELF_TEST
int FSProviderSelfTest(void);
#endif

void FSConfigureInterface(NSXPCInterface *interface);
void FSConfigureHostInterface(NSXPCInterface *interface);

NSDictionary *FSSettingsModel(void);
#if defined(FS_SELF_TEST) || defined(FS_MEDIA_TEST) || defined(FS_WIRE_PROOF)
NSDictionary *FSInspectSnapshot(id snapshot);
NSDictionary *FSInspectSettings(id settings);
// Test/host adapter: files are passed as real security-scoped URL wrappers.
id FSCreateRequest(NSDictionary *creation, NSArray<NSURL *> *files);
NSDictionary *FSInspectCreation(id request);
#endif
