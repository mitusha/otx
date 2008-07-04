/*
    Searchers64.m

    A category on Exe64Processor that contains the various binary search
    methods.

    This file is in the public domain.
*/

#import <Cocoa/Cocoa.h>

#import "Searchers64.h"

@implementation Exe64Processor(Searchers64)

//  findSymbolByAddress:
// ----------------------------------------------------------------------------

- (BOOL)findSymbolByAddress: (UInt32)inAddress
{
    if (!iFuncSyms)
        return NO;

    nlist searchKey = {{0}, 0, 0, 0, inAddress};
    BOOL symbolExists = (bsearch(&searchKey,
        iFuncSyms, iNumFuncSyms, sizeof(nlist),
        (COMPARISON_FUNC_TYPE)Sym_Compare) != NULL);

    return symbolExists;
}

//  findClassMethod:byAddress:
// ----------------------------------------------------------------------------

- (BOOL)findClassMethod: (Method64Info**)outMI
              byAddress: (UInt64)inAddress;
{
    if (!outMI)
        return NO;

    if (!iClassMethodInfos)
    {
        *outMI  = NULL;
        return NO;
    }

    Method64Info  searchKey   = {{0, 0, inAddress}, {0}, NO};

    *outMI  = bsearch(&searchKey,
        iClassMethodInfos, iNumClassMethodInfos, sizeof(Method64Info),
            (COMPARISON_FUNC_TYPE)
            (iSwapped ? Method64Info_Compare_Swapped : Method64Info_Compare));

    return (*outMI != NULL);
}

//  findIvar:inClass:withOffset:
// ----------------------------------------------------------------------------
// TODO: keep a sorted list of ClassInfo's, where each ClassInfo keeps a sorted
// list of objc2_ivar_t's.

- (BOOL)findIvar: (objc2_ivar_t**)outIvar
         inClass: (objc2_class_t*)inClass
      withOffset: (UInt64)inOffset
{
    if (!inClass || !outIvar)
        return NO;

    objc2_ivar_t searchKey = {inOffset, 0, 0, 0, 0};

    *outIvar = bsearch(&searchKey, iClassIvars, iNumClassIvars, sizeof(objc2_ivar_t),
        (COMPARISON_FUNC_TYPE)objc2_ivar_t_Compare);

    return (*outIvar != NULL);
}

@end
