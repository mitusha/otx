/*
    Searchers.m

    A category on Exe32Processor that contains the various binary search
    methods.

    This file is in the public domain.
*/

#import <Cocoa/Cocoa.h>

#import "Searchers.h"

@implementation Exe32Processor(Searchers)

//  findSymbolByAddress:
// ----------------------------------------------------------------------------

- (BOOL)findSymbolByAddress: (UInt32)inAddress
{
    if (!iFuncSyms)
        return NO;

    nlist searchKey = {{0}, 0, 0, 0, inAddress};
    BOOL symbolExists = (bsearch(&searchKey,
        iFuncSyms, iNumFuncSyms, sizeof(nlist),
        (COMPARISON_FUNC_TYPE)Sym_Compare) != nil);

    return symbolExists;
}

//  findClassMethod:byAddress:
// ----------------------------------------------------------------------------

- (BOOL)findClassMethod: (MethodInfo**)outMI
              byAddress: (UInt32)inAddress;
{
    if (!outMI)
        return NO;

    if (!iClassMethodInfos)
    {
        *outMI  = nil;
        return NO;
    }

    UInt32  swappedAddress  = inAddress;

    if (iSwapped)
        swappedAddress  = OSSwapInt32(swappedAddress);

    MethodInfo  searchKey   = {{nil, nil, (IMP)swappedAddress}, {0}, {0}, NO};

    *outMI  = bsearch(&searchKey,
        iClassMethodInfos, iNumClassMethodInfos, sizeof(MethodInfo),
            (COMPARISON_FUNC_TYPE)
            (iSwapped ? MethodInfo_Compare_Swapped : MethodInfo_Compare));

    return (*outMI != nil);
}

//  findCatMethod:byAddress:
// ----------------------------------------------------------------------------

- (BOOL)findCatMethod: (MethodInfo**)outMI
            byAddress: (UInt32)inAddress;
{
    if (!outMI)
        return NO;

    if (!iCatMethodInfos)
    {
        *outMI  = nil;
        return NO;
    }

    UInt32  swappedAddress  = inAddress;

    if (iSwapped)
        swappedAddress  = OSSwapInt32(swappedAddress);

    MethodInfo  searchKey   = {{nil, nil, (IMP)swappedAddress}, {0}, {0}, NO};

    *outMI  = bsearch(&searchKey,
        iCatMethodInfos, iNumCatMethodInfos, sizeof(MethodInfo),
            (COMPARISON_FUNC_TYPE)
            (iSwapped ? MethodInfo_Compare_Swapped : MethodInfo_Compare));

    return (*outMI != nil);
}

//  findIvar:inClass:withOffset:
// ----------------------------------------------------------------------------

- (BOOL)findIvar: (objc_ivar*)outIvar
         inClass: (objc_class*)inClass
      withOffset: (UInt32)inOffset
{
    if (!inClass || !outIvar)
        return NO;

    // Loop thru inClass and all superclasses.
    objc_class*         theClassPtr     = inClass;
    objc_class          theSwappedClass = *theClassPtr;
    objc_class          theDummyClass   = {0};
    char*               theSuperName    = nil;
    objc_ivar_list*     theIvars;

    while (theClassPtr)
    {
//      if (mSwapped)
//          swap_objc_class(&theSwappedClass);

        theIvars    = (objc_ivar_list*)GetPointer(
            (UInt32)theSwappedClass.ivars, nil);

        if (!theIvars)
        {   // Try again with the superclass.
            theSuperName    = GetPointer(
                (UInt32)theClassPtr->super_class, nil);

            if (!theSuperName)
                break;

            if (!GetObjcClassFromName(&theDummyClass, theSuperName))
                break;

            theClassPtr = &theDummyClass;

            continue;
        }

        UInt32  numIvars    = theIvars->ivar_count;

        if (iSwapped)
            numIvars    = OSSwapInt32(numIvars);

        // It would be nice to use bsearch(3) here, but there's too much
        // swapping.
        SInt64  begin   = 0;
        SInt64  end     = numIvars - 1;
        SInt64  split   = numIvars / 2;
        UInt32  offset;

        while (end >= begin)
        {
            offset  = theIvars->ivar_list[split].ivar_offset;

            if (iSwapped)
                offset  = OSSwapInt32(offset);

            if (offset == inOffset)
            {
                *outIvar    = theIvars->ivar_list[split];

                if (iSwapped)
                    swap_objc_ivar(outIvar);

                return YES;
            }

            if (offset > inOffset)
                end     = split - 1;
            else
                begin   = split + 1;

            split   = (begin + end) / 2;
        }

        // Try again with the superclass.
        theSuperName    = GetPointer((UInt32)theClassPtr->super_class, nil);

        if (!theSuperName)
            break;

        if (!GetObjcClassFromName(&theDummyClass, theSuperName))
            break;

        theClassPtr = &theDummyClass;
    }

    return NO;
}

@end
