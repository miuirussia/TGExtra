#import "SwiftgramPro.h"
#import "Constants.h"
#import <Tweak.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <stdatomic.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

bool TGExtraReplaceSwiftgramStatusWitness(const void *targetTable, const void *sourceTable) {
    if (!targetTable || !sourceTable) return false;
    void **target = (void **)targetTable + 1;
    void *const *source = (void *const *)sourceTable + 1;
    if (!*target || !*source) return false;

    // Both tables are instantiated by Swift for the same resilient protocol.
    // arm64e witnesses are signed against their slot and requirement discriminator.
    void *replacement = *source;
#if __has_feature(ptrauth_calls)
    const uint32_t *requirement = dlsym(RTLD_DEFAULT, "$sSe4fromxs7Decoder_p_tKcfCTq");
    if (!requirement || (*requirement & 0xF) != 2) return false; // Init
    uintptr_t discriminator = *requirement >> 16;
    replacement = ptrauth_auth_and_resign(replacement, ptrauth_key_function_pointer,
        ptrauth_blend_discriminator(source, discriminator), ptrauth_key_function_pointer,
        ptrauth_blend_discriminator(target, discriminator));
#endif

    vm_address_t region = (vm_address_t)target;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &region, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || (vm_address_t)target < region ||
        (vm_address_t)target + sizeof(void *) > region + size) return false;

    vm_address_t page = (vm_address_t)target & ~((vm_address_t)vm_page_size - 1);
    bool writable = (info.protection & VM_PROT_WRITE) != 0;
    if (!writable && vm_protect(mach_task_self(), page, vm_page_size, false,
        info.protection | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return false;
    atomic_store_explicit((_Atomic(void *) *)target, replacement, memory_order_release);
    if (!writable) vm_protect(mach_task_self(), page, vm_page_size, false, info.protection);
    return true;
}

#ifndef TGEXTRA_TESTING
__attribute__((constructor)) static void TGExtraSetupSwiftgramPro(void) {
    @autoreleasepool {
        if ([NSUserDefaults.standardUserDefaults boolForKey:kSwiftgramPro]) {
            bool installed = TGExtraInstallSwiftgramPro();
            if (!installed) NSLog(@"[TGExtra] Swiftgram Pro: compatible SGStatus witness unavailable");
        }
    }
}
#endif
