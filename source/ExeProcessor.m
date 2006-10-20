/*
	ExeProcessor.m

	This file relies upon, and steals code from, the cctools source code
	available from: http://www.opensource.apple.com/darwinsource/
*/

#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach-o/swap.h>
#import <objc/objc-runtime.h>
#import <sys/ptrace.h>
#import <sys/syscall.h>

#import "demangle.h"

#import "ExeProcessor.h"
#import "UserDefaultKeys.h"

// ----------------------------------------------------------------------------
// Comparison functions for qsort(3) and bsearch(3)

static int
sym_compare(
	nlist**	sym1,
	nlist**	sym2)
{
	if ((*sym1)->n_value < (*sym2)->n_value)
		return -1;

	return ((*sym1)->n_value > (*sym2)->n_value);
}

static int
methodInfo_compare(
	MethodInfo*	mi1,
	MethodInfo*	mi2)
{
	if (mi1->m.method_imp < mi2->m.method_imp)
		return -1;

	return (mi1->m.method_imp > mi2->m.method_imp);
}

// ============================================================================

@implementation ExeProcessor

// ExeProcessor is a base class that handles processor-independent issues.
// PPCProcessor and X86Processor are subclasses that add functionality
// specific to those CPUs. The AppController class creates a new instance of
// one of those subclasses class for each processing, and deletes the
// instance as soon as possible. Member variables may or may not be
// re-initialized before destruction. Do not reuse a single instance of
// those subclasses class for multiple processings.

//	initWithURL:progText:progBar:
// ----------------------------------------------------------------------------

- (id)initWithURL: (NSURL*)inURL
		 progText: (NSTextField*)inText
		  progBar: (NSProgressIndicator*)inProg
{
	if (!inURL || !inText || !inProg)
		return nil;

	if ((self = [super init]) == nil)
		return nil;

	mOFile		= inURL;
	mProgText	= inText;
	mProgBar	= inProg;

	mCurrentFuncInfoIndex	= -1;

	// Load exe into RAM.
	NSError*	theError	= nil;
	NSData*		theData		= [NSData dataWithContentsOfURL: mOFile
		options: 0 error: &theError];

	if (!theData)
	{
		printf("otx: error loading executable from disk: %s\n",
			CSTRING([theError localizedFailureReason]));
		[self release];
		return nil;
	}

	mRAMFileSize	= [theData length];

	if (mRAMFileSize < sizeof(mArchMagic))
	{
		printf("otx: truncated executable file\n");
		[theData release];
		[self release];
		return nil;
	}

	mRAMFile	= malloc(mRAMFileSize);

	if (!mRAMFile)
	{
		printf("otx: not enough memory to allocate mRAMFile\n");
		[theData release];
		[self release];
		return nil;
	}

	[theData getBytes: mRAMFile];

	mArchMagic	= *(UInt32*)mRAMFile;
	mExeIsFat	= mArchMagic == FAT_MAGIC || mArchMagic == FAT_CIGAM;

	[self speedyDelivery];

	return self;
}

//	dealloc
// ----------------------------------------------------------------------------

- (void)dealloc
{
	if (mRAMFile)
		free(mRAMFile);

	if (mFuncSyms)
		free(mFuncSyms);

	if (mObjcSects)
		free(mObjcSects);

	if (mClassMethodInfos)
		free(mClassMethodInfos);

	if (mCatMethodInfos)
		free(mCatMethodInfos);

	if (mThunks)
		free(mThunks);

	[self deleteFuncInfos];
	[self deleteLinesFromList: mPlainLineListHead];
	[self deleteLinesFromList: mVerboseLineListHead];

	[super dealloc];
}

//	deleteFuncInfos
// ----------------------------------------------------------------------------

- (void)deleteFuncInfos
{
	if (!mFuncInfos)
		return;

	UInt32			i;
	UInt32			j;
	FunctionInfo*	funcInfo;
	BlockInfo*		blockInfo;

	for (i = 0; i < mNumFuncInfos; i++)
	{
		funcInfo	= &mFuncInfos[i];

		if (funcInfo->blocks)
		{
			for (j = 0; j < funcInfo->numBlocks; j++)
			{
				blockInfo	= &funcInfo->blocks[j];

				if (blockInfo->state.regInfos)
				{
					free(blockInfo->state.regInfos);
					blockInfo->state.regInfos	= nil;
				}

				if (blockInfo->state.localSelves)
				{
					free(blockInfo->state.localSelves);
					blockInfo->state.localSelves	= nil;
				}
			}

			free(funcInfo->blocks);
			funcInfo->blocks	= nil;
		}
	}

	free(mFuncInfos);
	mFuncInfos	= nil;
}

//	processExe:arch:
// ----------------------------------------------------------------------------

- (BOOL)processExe: (NSString*)inOutputFilePath
{
	if (!mArchMagic)
	{
		printf("otx: tried to process non-machO file\n");
		return false;
	}

	mOutputFilePath	= inOutputFilePath;
	mMachHeader		= nil;

	// Save some prefs for speed.
	NSUserDefaults*	theDefaults	= [NSUserDefaults standardUserDefaults];

	mShowLocalOffsets		= [theDefaults boolForKey: ShowLocalOffsetsKey];
	mShowDataSection		= [theDefaults boolForKey: ShowDataSectionKey];
	mShowMethReturnTypes	= [theDefaults boolForKey: ShowMethodReturnTypesKey];
	mShowIvarTypes			= [theDefaults boolForKey: ShowIvarTypesKey];
	mEntabOutput			= [theDefaults boolForKey: EntabOutputKey];
	mDemangleCppNames		= [theDefaults boolForKey: DemangleCppNamesKey];

	if (![self loadMachHeader])
	{
		printf("otx: failed to load mach header\n");
		return false;
	}

	[self loadLCommands];

	[mProgText setStringValue: @"Calling otool"];
	[mProgText display];

	// Create temp files.
	NSURL*	theVerboseFile	= nil;
	NSURL*	thePlainFile	= nil;

	[self createVerboseFile: &theVerboseFile andPlainFile: &thePlainFile];

	if (!theVerboseFile || !thePlainFile)
	{
		printf("otx: could not create temp files\n");
		return false;
	}

	// Get the party started.
	if (![self processVerboseFile: theVerboseFile andPlainFile: thePlainFile])
	{
		printf("otx: unable to process temp files\n");
		return false;
	}

	// Delete temp files.
	NSFileManager*	theFileMan	= [NSFileManager defaultManager];

	[theFileMan removeFileAtPath: [theVerboseFile path] handler: nil];
	[theFileMan removeFileAtPath: [thePlainFile path] handler: nil];

	return true;
}

//	createVerboseFile:andPlainFile:
// ----------------------------------------------------------------------------
//	Call otool on the exe too many times.

- (void)createVerboseFile: (NSURL**)outVerbosePath
			 andPlainFile: (NSURL**)outPlainPath
{
	NSString*	oPath			= [mOFile path];
	NSString*	otoolString;
	char		cmdString[100]	= {0};
	char*		cmdFormatString	= mExeIsFat ? "otool -arch %s" : "otool";

	snprintf(cmdString, MAX_ARCH_STRING_LENGTH + 1,
		cmdFormatString, mArchString);

	NSString*	verbosePath	= [NSTemporaryDirectory()
		stringByAppendingPathComponent: @"temp1.otx"];
	NSString*	plainPath	= [NSTemporaryDirectory()
		stringByAppendingPathComponent: @"temp2.otx"];

	// The following lines call otool twice for each section we want, once
	// with verbosity, once without. sed removes the 1st line from sections
	// other than the first text section, which is a redundant filepath.
	// The first system call creates or overwrites the file at verbosePath,
	// subsequent calls append to the file. The order in which sections are
	// printed may not reflect their order in the executable.

	[mProgBar animate: self];
	[mProgBar display];

	// Create verbose temp file.
	otoolString	= [NSString stringWithFormat:
		@"%s -V -s __TEXT __text '%@' > '%@'",
		cmdString, oPath, verbosePath];

	if (system(CSTRING(otoolString)) != noErr)
		return;

	[mProgBar animate: self];
	[mProgBar display];

	// Create non-verbose temp file.
	otoolString	= [NSString stringWithFormat:
		@"%s -v -s __TEXT __text '%@' > '%@'",
		cmdString, oPath, plainPath];
	system(CSTRING(otoolString));

	[mProgBar animate: self];
	[mProgBar display];

	// Append to verbose temp file.
	otoolString	= [NSString stringWithFormat:
		@"%s -V -s __TEXT __coalesced_text '%@' | sed '1 d' >> '%@'",
		cmdString, oPath, verbosePath];
	system(CSTRING(otoolString));

	[mProgBar animate: self];
	[mProgBar display];

	// Append to non-verbose temp file.
	otoolString	= [NSString stringWithFormat:
		@"%s -v -s __TEXT __coalesced_text '%@' | sed '1 d' >> '%@'",
		cmdString, oPath, plainPath];
	system(CSTRING(otoolString));

	[mProgBar animate: self];
	[mProgBar display];

	// Append to verbose temp file.
	otoolString	= [NSString stringWithFormat:
		@"%s -V -s __TEXT __textcoal_nt '%@' | sed '1 d' >> '%@'",
		cmdString, oPath, verbosePath];
	system(CSTRING(otoolString));

	[mProgBar animate: self];
	[mProgBar display];

	// Append to non-verbose temp file.
	otoolString	= [NSString stringWithFormat:
		@"%s -v -s __TEXT __textcoal_nt '%@' | sed '1 d' >> '%@'",
		cmdString, oPath, plainPath];
	system(CSTRING(otoolString));

	*outVerbosePath	= [NSURL fileURLWithPath: verbosePath];
	*outPlainPath	= [NSURL fileURLWithPath: plainPath];
}

#pragma mark -
// The loadXXX methods just store pointers to various data structures in the
// exe file(swapped in-place if needed), with the exception of loadObjcSection,
// which stores copies of those sections for later use with the getXXX methods,
// stolen from cctools.

//	loadMachHeader
// ----------------------------------------------------------------------------
//	Assuming mRAMFile points to RAM that contains the contents of the exe, we
//	can set our mach_header* to point to the appropriate mach header, whether
//	the exe is unibin or not.

- (BOOL)loadMachHeader
{
	// Convert possible unibin to a single arch.
	if (mArchMagic	== FAT_MAGIC ||
		mArchMagic	== FAT_CIGAM)
	{
		fat_header*	fh	= (fat_header*)mRAMFile;
		fat_arch*	fa	= (fat_arch*)(fh + 1);

		// fat_header and fat_arch are always big-endian. Swap if we're
		// running on intel.
		if (OSHostByteOrder() == OSLittleEndian)
		{
			swap_fat_header(fh, OSLittleEndian);				// one header
			swap_fat_arch(fa, fh->nfat_arch, OSLittleEndian);	// multiple archs
		}

		UInt32	i;

		// Find the mach header we want.
		for (i = 0; i < fh->nfat_arch && !mMachHeader; i++)
		{
			if (fa->cputype == mArchSelector)
			{
				mMachHeader	= (mach_header*)(mRAMFile + fa->offset);
				mArchMagic	= *(UInt32*)mMachHeader;
				mSwapped	= mArchMagic == MH_CIGAM;
			}

			fa++;	// next arch
		}

		if (!mMachHeader)
			printf("otx: architecture not found in unibin\n");
	}
	else	// not a unibin, so mach header = start of file.
	{
		switch (mArchMagic)
		{
			case MH_CIGAM:
				mSwapped = true;	// fall thru
			case MH_MAGIC:
				mMachHeader	=  (mach_header*)mRAMFile;
				break;

			default:
				printf("otx: unknown magic value: 0x%x\n", mArchMagic);
				break;
		}
	}

	if (!mMachHeader)
	{
		printf("otx: mach header not found\n");
		return false;
	}

	if (mSwapped)
		swap_mach_header(mMachHeader, OSHostByteOrder());

	return true;
}

//	loadLCommands
// ----------------------------------------------------------------------------
//	From the mach_header ptr, loop thru the load commands for each segment.

- (void)loadLCommands
{
	// We need byte pointers for pointer arithmetic. Set a pointer to the 1st
	// load command.
	char*	ptr	= (char*)(mMachHeader + 1);
	UInt16	i;

	// Loop thru load commands.
	for (i = 0; i < mMachHeader->ncmds; i++)
	{
		// Copy the load_command so we can:
		// -Swap it if needed without double-swapping parts of segments
		//		and symtabs.
		// -Easily advance to next load_command at end of loop regardless
		//		of command type.
		load_command	theCommandCopy	= *(load_command*)ptr;

		if (mSwapped)
			swap_load_command(&theCommandCopy, OSHostByteOrder());

		switch (theCommandCopy.cmd)
		{
			case LC_SEGMENT:
			{
				// Re-cast the original ptr as a segment_command.
				segment_command*	segPtr	= (segment_command*)ptr;

				if (mSwapped)
					swap_segment_command(segPtr, OSHostByteOrder());

				// Load a segment we're interested in.
				if (!strcmp(segPtr->segname, SEG_TEXT))
				{
					mTextOffset	= segPtr->vmaddr - segPtr->fileoff;
					[self loadSegment: segPtr];
				}
				else if (!strcmp(segPtr->segname, SEG_DATA))
				{
					[self loadSegment: segPtr];
				}
				else if (!strcmp(segPtr->segname, SEG_OBJC))
					[self loadSegment: segPtr];
				else if (!strcmp(segPtr->segname, "__IMPORT"))
					[self loadSegment: segPtr];

				break;
			}

			case LC_SYMTAB:
			{
				// Re-cast the original ptr as a symtab_command.
				symtab_command*	symTab	= (symtab_command*)ptr;

				if (mSwapped)
					swap_symtab_command(symTab, OSHostByteOrder());

				[self loadSymbols: symTab];

				break;
			}
/*			case LC_DYSYMTAB:
			{
				// Re-cast the original ptr as a dysymtab_command.
				dysymtab_command*	dySymTab	= (dysymtab_command*)ptr;

				if (mSwapped)
					swap_dysymtab_command(dySymTab, OSHostByteOrder());

				[self loadDySymbols: dySymTab];

				break;
			}*/

			default:
				break;
		}

		// Point to the next command.
		ptr	+= theCommandCopy.cmdsize;
	}	// for(i = 0; i < mMachHeader->ncmds; i++)

	// Now that we have all the objc sections, we can load the objc modules.
	[self loadObjcModules];
}

//	loadSegment:
// ----------------------------------------------------------------------------
//	Given a pointer to a segment, loop thru its sections and save whatever
//	we'll need later.

- (void)loadSegment: (segment_command*)inSegPtr
{
	// Set a pointer to the first section.
	char*	ptr	= (char*)inSegPtr + sizeof(segment_command);
	UInt16	i;

	// 'swap_section' acts more like 'swap_sections'. It is possible to
	// loop thru unreadable sections and swap them one at a time. Fuck it.
	if (mSwapped)
		swap_section((section*)ptr, inSegPtr->nsects, OSHostByteOrder());

	// Loop thru sections.
	section*	theSect	= nil;

	for (i = 0; i < inSegPtr->nsects; i++)
	{
		theSect	= (section*)ptr;

		if (!strcmp(theSect->segname, SEG_OBJC))
		{
			[self loadObjcSection: theSect];
		}
		else if (!strcmp(theSect->segname, SEG_TEXT))
		{
			if (!strcmp(theSect->sectname, SECT_TEXT))
				[self loadTextSection: theSect];
			else if (!strncmp(theSect->sectname, "__coalesced_text", 16))
				[self loadCoalTextSection: theSect];
			else if (!strcmp(theSect->sectname, "__textcoal_nt"))
				[self loadCoalTextNTSection: theSect];
			else if (!strcmp(theSect->sectname, "__const"))
				[self loadConstTextSection: theSect];
			else if (!strcmp(theSect->sectname, "__cstring"))
				[self loadCStringSection: theSect];
			else if (!strcmp(theSect->sectname, "__literal4"))
				[self loadLit4Section: theSect];
			else if (!strcmp(theSect->sectname, "__literal8"))
				[self loadLit8Section: theSect];
		}
		else if (!strcmp(theSect->segname, SEG_DATA))
		{
			if (!strcmp(theSect->sectname, SECT_DATA))
				[self loadDataSection: theSect];
			else if (!strncmp(theSect->sectname, "__coalesced_data", 16))
				[self loadCoalDataSection: theSect];
			else if (!strcmp(theSect->sectname, "__datacoal_nt"))
				[self loadCoalDataNTSection: theSect];
			else if (!strcmp(theSect->sectname, "__const"))
				[self loadConstDataSection: theSect];
			else if (!strcmp(theSect->sectname, "__dyld"))
				[self loadDyldDataSection: theSect];
			else if (!strcmp(theSect->sectname, "__cfstring"))
				[self loadCFStringSection: theSect];
			else if (!strcmp(theSect->sectname, "__nl_symbol_ptr"))
				[self loadNonLazySymbolSection: theSect];
		}
		else if (!strcmp(theSect->segname, "__IMPORT"))
		{
			if (!strcmp(theSect->sectname, "__pointers"))
				[self loadImpPtrSection: theSect];
		}

//		else if (!strncmp(theSect->sectname, "__picsymbol_stub", 16))
//			printf("found PIC section.\n");
//		else if (!strcmp(theSect->sectname, "__symbol_stub"))
//			printf("found indirect symbol stub section.\n");

		ptr	+= sizeof(section);
	}
}

//	loadSymbols:
// ----------------------------------------------------------------------------
//	This refers to the symbol table contained in the SEG_LINKEDIT segment.
//	See loadObjcSymTabFromModule for ObjC symbols.

- (void)loadSymbols: (symtab_command*)inSymPtr
{
//	nlist(3) doesn't quite cut it...

	nlist*	theSyms	= (nlist*)((char*)mMachHeader + inSymPtr->symoff);
	UInt32	i;

	if (mSwapped)
		swap_nlist(theSyms, inSymPtr->nsyms, OSHostByteOrder());

	// loop thru symbols
	for (i = 0; i < inSymPtr->nsyms; i++)
	{
		nlist	theSym		= theSyms[i];

		if (theSym.n_value == 0)
			continue;

		if ((theSym.n_type & N_STAB) == 0)	// not a STAB
		{
			if ((theSym.n_type & N_SECT) != N_SECT)
				continue;

			mNumFuncSyms++;

			if (mFuncSyms)
				mFuncSyms	= realloc(mFuncSyms,
					mNumFuncSyms * sizeof(nlist*));
			else
				mFuncSyms	= malloc(sizeof(nlist*));

			mFuncSyms[mNumFuncSyms - 1]	= &theSyms[i];

#if _OTX_DEBUG_SYMBOLS_
			[self printSymbol: theSym];
#endif
		}

	}	// for (i = 0; i < inSymPtr->nsyms; i++)

	// Sort the symbols so we can use binary searches later.
	qsort(mFuncSyms, mNumFuncSyms, sizeof(nlist*),
		(int (*)(const void*, const void*))sym_compare);
}

//	loadDySymbols:
// ----------------------------------------------------------------------------

- (void)loadDySymbols: (dysymtab_command*)inSymPtr
{
	nlist*	theSyms	= (nlist*)((char*)mMachHeader + inSymPtr->indirectsymoff);
	UInt32	i;

	if (mSwapped)
		swap_nlist(theSyms, inSymPtr->nindirectsyms, OSHostByteOrder());

	// loop thru symbols
	for (i = 0; i < inSymPtr->nindirectsyms; i++)
	{
#if _OTX_DEBUG_DYSYMBOLS_
		nlist	theSym		= theSyms[i];

		[self printSymbol: theSym];
#endif
	}
}

//	loadObjcSection:
// ----------------------------------------------------------------------------

- (void)loadObjcSection: (section*)inSect
{
	mNumObjcSects++;

	if (mObjcSects)
		mObjcSects	= realloc(mObjcSects,
			mNumObjcSects * sizeof(section_info));
	else
		mObjcSects	= malloc(sizeof(section_info));

	mObjcSects[mNumObjcSects - 1]	= (section_info)
		{*inSect, (char*)mMachHeader + inSect->offset, inSect->size};

	if (!strncmp(inSect->sectname, "__cstring_object", 16))
		[self loadNSStringSection: inSect];
	else if (!strcmp(inSect->sectname, "__class"))
		[self loadClassSection: inSect];
	else if (!strcmp(inSect->sectname, "__meta_class"))
		[self loadMetaClassSection: inSect];
	else if (!strcmp(inSect->sectname, "__instance_vars"))
		[self loadIVarSection: inSect];
	else if (!strcmp(inSect->sectname, "__module_info"))
		[self loadObjcModSection: inSect];
	else if (!strcmp(inSect->sectname, "__symbols"))
		[self loadObjcSymSection: inSect];
}

//	loadObjcModules
// ----------------------------------------------------------------------------

- (void)loadObjcModules
{
	char*			theMachPtr	= (char*)mMachHeader;
	char*			theModPtr;
	section_info*	theSectInfo;
	objc_module		theModule;
	UInt32			theModSize;
	objc_symtab		theSymTab;
	objc_class		theClass;
	objc_category	theCat;
	void**			theDefs;
	UInt32			theOffset;
	UInt32			i, j, k;

	// Loop thru objc sections.
	for (i = 0; i < mNumObjcSects; i++)
	{
		theSectInfo	= &mObjcSects[i];

		// Bail if not a module section.
		if (strcmp(theSectInfo->s.sectname, SECT_OBJC_MODULES))
			continue;

		theOffset	= theSectInfo->s.addr - theSectInfo->s.offset;
		theModPtr	= theMachPtr + theSectInfo->s.addr - theOffset;
		theModule	= *(objc_module*)theModPtr;

		if (mSwapped)
			swap_objc_module(&theModule);

		theModSize	= theModule.size;

		// Loop thru modules.
		while (theModPtr < theMachPtr + theSectInfo->s.offset + theSectInfo->s.size)
		{
			// Try to locate the objc_symtab for this module.
			if (![self getObjcSymtab: &theSymTab andDefs: &theDefs
				fromModule: &theModule] || !theDefs)
			{
				// point to next module
				theModPtr	+= theModSize;
				theModule	= *(objc_module*)theModPtr;

				if (mSwapped)
					swap_objc_module(&theModule);

				theModSize	= theModule.size;

				continue;
			}

// In the objc_symtab struct defined in <objc/objc-runtime.h>, the format of
// the void* array 'defs' is 'cls_def_cnt' class pointers followed by
// 'cat_def_cnt' category pointers.
			UInt32	theDef;

			// Loop thru class definitions in the objc_symtab.
			for (j = 0; j < theSymTab.cls_def_cnt; j++)
			{
				// Try to locate the objc_class for this def.
				UInt32	theDef	= (UInt32)theDefs[j];

				if (mSwapped)
					theDef	= OSSwapInt32(theDef);

				if (![self getObjcClass: &theClass fromDef: theDef])
					continue;

				// Save class's instance method info.
				objc_method_list	theMethodList;
				objc_method*		theMethods;
				objc_method			theMethod;

				if ([self getObjcMethodList: &theMethodList
					andMethods: &theMethods
					fromAddress: (UInt32)theClass.methodLists])
				{
					for (k = 0; k < theMethodList.method_count; k++)
					{
						theMethod	= theMethods[k];

						if (mSwapped)
							swap_objc_method(&theMethod);

						MethodInfo	theMethInfo	=
							{theMethod, theClass, {0}, true};

						mNumClassMethodInfos++;

						if (mClassMethodInfos)
							mClassMethodInfos	= realloc(mClassMethodInfos,
								mNumClassMethodInfos * sizeof(MethodInfo));
						else
							mClassMethodInfos	= malloc(sizeof(MethodInfo));

						mClassMethodInfos[mNumClassMethodInfos - 1]	= theMethInfo;
					}
				}

				// Save class's class method info.
				objc_class	theMetaClass;

				if ([self getObjcMetaClass: &theMetaClass
					fromClass: &theClass])
				{
					if ([self getObjcMethodList: &theMethodList
						andMethods: &theMethods
						fromAddress: (UInt32)theMetaClass.methodLists])
					{
						for (k = 0; k < theMethodList.method_count; k++)
						{
							theMethod	= theMethods[k];

							if (mSwapped)
								swap_objc_method(&theMethod);

							MethodInfo	theMethInfo	=
								{theMethod, theClass, {0}, false};

							mNumClassMethodInfos++;

							if (mClassMethodInfos)
								mClassMethodInfos	= realloc(
									mClassMethodInfos, mNumClassMethodInfos *
									sizeof(MethodInfo));
							else
								mClassMethodInfos	=
									malloc(sizeof(MethodInfo));

							mClassMethodInfos[mNumClassMethodInfos - 1]	=
								theMethInfo;
						}
					}

					if (theMetaClass.ivars)
					{	// trigger this code and win a free beer.
						printf("otx: found meta class ivars!\n");
					}
				}	// theMetaClass != nil
			}

			// Loop thru category definitions in the objc_symtab.
			for (; j < theSymTab.cat_def_cnt + theSymTab.cls_def_cnt; j++)
			{
				// Try to locate the objc_category for this def.
				theDef	= (UInt32)theDefs[j];

				if (mSwapped)
					theDef	= OSSwapInt32(theDef);

				if (![self getObjcCategory: &theCat fromDef: theDef])
					continue;

				// Categories are linked to classes by name only. Try to 
				// find the class for this category. May be nil.
				ObjcClassFromName(&theClass,
					GetPointer((UInt32)theCat.class_name, nil));

				// Save category instance method info.
				objc_method_list	theMethodList;
				objc_method*		theMethods;
				objc_method			theMethod;

				if ([self getObjcMethodList: &theMethodList
					andMethods: &theMethods
					fromAddress: (UInt32)theCat.instance_methods])
				{
					for (k = 0; k < theMethodList.method_count; k++)
					{
						theMethod	= theMethods[k];

						if (mSwapped)
							swap_objc_method(&theMethod);

						MethodInfo	theMethInfo	=
							{theMethod, theClass, theCat, true};

						mNumCatMethodInfos++;

						if (mCatMethodInfos)
							mCatMethodInfos	= realloc(mCatMethodInfos,
								mNumCatMethodInfos * sizeof(MethodInfo));
						else
							mCatMethodInfos	= malloc(sizeof(MethodInfo));

						mCatMethodInfos[mNumCatMethodInfos - 1]	= theMethInfo;
					}
				}

				// Save category class method info.
				if ([self getObjcMethodList: &theMethodList
					andMethods: &theMethods
					fromAddress: (UInt32)theCat.class_methods])
				{
					for (k = 0; k < theMethodList.method_count; k++)
					{
						theMethod	= theMethods[k];

						if (mSwapped)
							swap_objc_method(&theMethod);

						MethodInfo	theMethInfo	=
							{theMethod, theClass, theCat, false};

						mNumCatMethodInfos++;

						if (mCatMethodInfos)
							mCatMethodInfos	=
							realloc(mCatMethodInfos,
								mNumCatMethodInfos * sizeof(MethodInfo));
						else
							mCatMethodInfos	= malloc(sizeof(MethodInfo));

						mCatMethodInfos[mNumCatMethodInfos - 1]	= theMethInfo;
					}
				}
			}	// for (; j < theSymTab.cat_def_cnt; j++)

			// point to next module
			theModPtr	+= theModSize;
			theModule	= *(objc_module*)theModPtr;

			if (mSwapped)
				swap_objc_module(&theModule);

			theModSize	= theModule.size;
		}	// while (theModPtr...)
	}	// for (i = 0; i < mNumObjcSects; i++)

	// Sort MethodInfos.
	qsort(mClassMethodInfos, mNumClassMethodInfos, sizeof(MethodInfo),
		(int (*)(const void*, const void*))methodInfo_compare);
	qsort(mCatMethodInfos, mNumCatMethodInfos, sizeof(MethodInfo),
		(int (*)(const void*, const void*))methodInfo_compare);
}

//	loadCStringSection:
// ----------------------------------------------------------------------------

- (void)loadCStringSection: (section*)inSect
{
	mCStringSect.s			= *inSect;
	mCStringSect.contents	= (char*)mMachHeader + inSect->offset;
	mCStringSect.size		= inSect->size;
}

//	loadNSStringSection:
// ----------------------------------------------------------------------------

- (void)loadNSStringSection: (section*)inSect
{
	mNSStringSect.s			= *inSect;
	mNSStringSect.contents	= (char*)mMachHeader + inSect->offset;
	mNSStringSect.size		= inSect->size;
}

//	loadClassSection:
// ----------------------------------------------------------------------------

- (void)loadClassSection: (section*)inSect
{
	mClassSect.s		= *inSect;
	mClassSect.contents	= (char*)mMachHeader + inSect->offset;
	mClassSect.size		= inSect->size;
}

//	loadMetaClassSection:
// ----------------------------------------------------------------------------

- (void)loadMetaClassSection: (section*)inSect
{
	mMetaClassSect.s		= *inSect;
	mMetaClassSect.contents	= (char*)mMachHeader + inSect->offset;
	mMetaClassSect.size		= inSect->size;
}

//	loadIVarSection:
// ----------------------------------------------------------------------------

- (void)loadIVarSection: (section*)inSect
{
	mIVarSect.s			= *inSect;
	mIVarSect.contents	= (char*)mMachHeader + inSect->offset;
	mIVarSect.size		= inSect->size;
}

//	loadObjcModSection:
// ----------------------------------------------------------------------------

- (void)loadObjcModSection: (section*)inSect
{
	mObjcModSect.s			= *inSect;
	mObjcModSect.contents	= (char*)mMachHeader + inSect->offset;
	mObjcModSect.size		= inSect->size;
}

//	loadObjcSymSection:
// ----------------------------------------------------------------------------

- (void)loadObjcSymSection: (section*)inSect
{
	mObjcSymSect.s			= *inSect;
	mObjcSymSect.contents	= (char*)mMachHeader + inSect->offset;
	mObjcSymSect.size		= inSect->size;
}

//	loadLit4Section:
// ----------------------------------------------------------------------------

- (void)loadLit4Section: (section*)inSect
{
	mLit4Sect.s			= *inSect;
	mLit4Sect.contents	= (char*)mMachHeader + inSect->offset;
	mLit4Sect.size		= inSect->size;
}

//	loadLit8Section:
// ----------------------------------------------------------------------------

- (void)loadLit8Section: (section*)inSect
{
	mLit8Sect.s			= *inSect;
	mLit8Sect.contents	= (char*)mMachHeader + inSect->offset;
	mLit8Sect.size		= inSect->size;
}

//	loadTextSection:
// ----------------------------------------------------------------------------

- (void)loadTextSection: (section*)inSect
{
	mTextSect.s			= *inSect;
	mTextSect.contents	= (char*)mMachHeader + inSect->offset;
	mTextSect.size		= inSect->size;

	mEndOfText	= mTextSect.s.addr + mTextSect.s.size;
}

//	loadConstTextSection:
// ----------------------------------------------------------------------------

- (void)loadConstTextSection: (section*)inSect
{
	mConstTextSect.s		= *inSect;
	mConstTextSect.contents	= (char*)mMachHeader + inSect->offset;
	mConstTextSect.size		= inSect->size;
}

//	loadCoalTextSection:
// ----------------------------------------------------------------------------

- (void)loadCoalTextSection: (section*)inSect
{
	mCoalTextSect.s			= *inSect;
	mCoalTextSect.contents	= (char*)mMachHeader + inSect->offset;
	mCoalTextSect.size		= inSect->size;
}

//	loadCoalTextNTSection:
// ----------------------------------------------------------------------------

- (void)loadCoalTextNTSection: (section*)inSect
{
	mCoalTextNTSect.s			= *inSect;
	mCoalTextNTSect.contents	= (char*)mMachHeader + inSect->offset;
	mCoalTextNTSect.size		= inSect->size;
}

//	loadDataSection:
// ----------------------------------------------------------------------------

- (void)loadDataSection: (section*)inSect
{
	mDataSect.s			= *inSect;
	mDataSect.contents	= (char*)mMachHeader + inSect->offset;
	mDataSect.size		= inSect->size;
}

//	loadCoalDataSection:
// ----------------------------------------------------------------------------

- (void)loadCoalDataSection: (section*)inSect
{
	mCoalDataSect.s			= *inSect;
	mCoalDataSect.contents	= (char*)mMachHeader + inSect->offset;
	mCoalDataSect.size		= inSect->size;
}

//	loadCoalDataNTSection:
// ----------------------------------------------------------------------------

- (void)loadCoalDataNTSection: (section*)inSect
{
	mCoalDataNTSect.s			= *inSect;
	mCoalDataNTSect.contents	= (char*)mMachHeader + inSect->offset;
	mCoalDataNTSect.size		= inSect->size;
}

//	loadConstDataSection:
// ----------------------------------------------------------------------------

- (void)loadConstDataSection: (section*)inSect
{
	mConstDataSect.s		= *inSect;
	mConstDataSect.contents	= (char*)mMachHeader + inSect->offset;
	mConstDataSect.size		= inSect->size;
}

//	loadDyldDataSection:
// ----------------------------------------------------------------------------

- (void)loadDyldDataSection: (section*)inSect
{
	mDyldSect.s			= *inSect;
	mDyldSect.contents	= (char*)mMachHeader + inSect->offset;
	mDyldSect.size		= inSect->size;

	if (mDyldSect.size < sizeof(dyld_data_section))
		return;

	dyld_data_section*	data	= (dyld_data_section*)mDyldSect.contents;

	mAddrDyldStubBindingHelper	= (UInt32)(data->dyld_stub_binding_helper);

	if (mSwapped)
		mAddrDyldStubBindingHelper	=
			OSSwapInt32(mAddrDyldStubBindingHelper);
}

//	loadCFStringSection:
// ----------------------------------------------------------------------------

- (void)loadCFStringSection: (section*)inSect
{
	mCFStringSect.s			= *inSect;
	mCFStringSect.contents	= (char*)mMachHeader + inSect->offset;
	mCFStringSect.size		= inSect->size;
}

//	loadNonLazySymbolSection:
// ----------------------------------------------------------------------------

- (void)loadNonLazySymbolSection: (section*)inSect
{
	mNLSymSect.s		= *inSect;
	mNLSymSect.contents	= (char*)mMachHeader + inSect->offset;
	mNLSymSect.size		= inSect->size;
}

//	loadImpPtrSection:
// ----------------------------------------------------------------------------

- (void)loadImpPtrSection: (section*)inSect
{
	mImpPtrSect.s			= *inSect;
	mImpPtrSect.contents	= (char*)mMachHeader + inSect->offset;
	mImpPtrSect.size		= inSect->size;
}

#pragma mark -
//	processVerboseFile:andPlainFile:
// ----------------------------------------------------------------------------

- (BOOL)processVerboseFile: (NSURL*)inVerboseFile
			  andPlainFile: (NSURL*)inPlainFile
{
	// Load otool's outputs into parallel doubly-linked lists of C strings.
	// List heads have nil 'prev'. List tails have nil 'next'.
	const char*	verbosePath	= CSTRING([inVerboseFile path]);
	const char*	plainPath	= CSTRING([inPlainFile path]);

	FILE*	verboseFile	= fopen(verbosePath, "r");

	if (!verboseFile)
	{
		perror("otx: unable to open verbose temp file");
		return false;
	}

	FILE*	plainFile	= fopen(plainPath, "r");

	if (!plainFile)
	{
		perror("otx: unable to open plain temp file");
		return false;
	}

	char	theVerboseCLine[MAX_LINE_LENGTH];
	char	thePlainCLine[MAX_LINE_LENGTH];
	Line*	thePrevVerboseLine	= nil;
	Line*	thePrevPlainLine	= nil;
	SInt32	theFileError;

	// Loop thru lines in the temp files.
	while (!feof(verboseFile) && !feof(plainFile))
	{
		bzero(theVerboseCLine, MAX_LINE_LENGTH);
		bzero(thePlainCLine, MAX_LINE_LENGTH);

		if (!fgets(theVerboseCLine, MAX_LINE_LENGTH, verboseFile))
		{
			theFileError	= ferror(verboseFile);

			if (theFileError)
				printf("otx: error reading from verbose temp file: %d\n",
					theFileError);

			break;
		}

		if (!fgets(thePlainCLine, MAX_LINE_LENGTH, plainFile))
		{
			theFileError	= ferror(plainFile);

			if (theFileError)
				printf("otx: error reading from plain temp file: %d\n",
					theFileError);

			break;
		}

		Line*	theVerboseLine	= malloc(sizeof(Line));
		Line*	thePlainLine	= malloc(sizeof(Line));

		bzero(theVerboseLine, sizeof(Line));
		bzero(thePlainLine, sizeof(Line));
		theVerboseLine->length	= strlen(theVerboseCLine);
		thePlainLine->length	= strlen(thePlainCLine);
		theVerboseLine->chars	= malloc(theVerboseLine->length + 1);
		thePlainLine->chars		= malloc(thePlainLine->length + 1);
		strncpy(theVerboseLine->chars, theVerboseCLine,
			theVerboseLine->length + 1);
		strncpy(thePlainLine->chars, thePlainCLine,
			thePlainLine->length + 1);

		// Connect the plain and verbose lines.
		theVerboseLine->alt	= thePlainLine;
		thePlainLine->alt	= theVerboseLine;

		// Add the lines to the lists.
		InsertLineAfter(theVerboseLine, thePrevVerboseLine,
			&mVerboseLineListHead);
		InsertLineAfter(thePlainLine, thePrevPlainLine,
			&mPlainLineListHead);

		thePrevVerboseLine	= theVerboseLine;
		thePrevPlainLine	= thePlainLine;
		mNumLines++;
	}

	if (fclose(verboseFile) != 0)
	{
		perror("otx: unable to close verbose temp file");
		return false;
	}

	if (fclose(plainFile) != 0)
	{
		perror("otx: unable to close plain temp file");
		return false;
	}

	// Optionally insert md5.
	if ([[NSUserDefaults standardUserDefaults] boolForKey: ShowMD5Key])
		[self insertMD5];

	// Gather info about lines while they're virgin.
	[mProgText setStringValue: @"Gathering info"];
	[mProgText display];
	[self gatherLineInfos];

	UInt32	progCounter	= 0;

	[mProgBar setIndeterminate: false];
	[mProgBar setDoubleValue: 0];
	[mProgText setStringValue: @"Generating file"];
	[mProgBar display];
	[mProgText display];

	Line*	theLine	= mPlainLineListHead;

	// Loop thru lines.
	while (theLine)
	{
		if (!(progCounter % PROGRESS_FREQ))
		{
			[mProgBar setDoubleValue:
				(double)progCounter / mNumLines * 100];
			[mProgBar display];
		}

		if (theLine->info.isCode)
		{
			ProcessCodeLine(&theLine);

			if (mEntabOutput)
				EntabLine(theLine);
		}
		else
			ProcessLine(theLine);

		theLine	= theLine->next;
		progCounter++;
	}

	[mProgText setStringValue: @"Writing __TEXT segment"];
	[mProgBar setIndeterminate: true];
	[mProgText display];
	[mProgBar display];

	// Create output file.
	if (![self printLinesFromList: mPlainLineListHead])
		return false;

	if (mShowDataSection)
	{
		[mProgText setStringValue: @"Writing __DATA segment"];
		[mProgBar animate: self];
		[mProgText display];
		[mProgBar display];

		if (![self printDataSections])
			return false;
	}

	return true;
}

//	gatherLineInfos
// ----------------------------------------------------------------------------
//	To make life easier as we make changes to the lines, whatever info we need
//	is harvested early here.

- (void)gatherLineInfos
{
	Line*	theLine		= mPlainLineListHead;
	UInt32	progCounter	= 0;

	while (theLine)
	{
		if (!(progCounter % (PROGRESS_FREQ * 3)))
		{
			[mProgBar animate: self];
			[mProgBar display];
		}

		if (LineIsCode(theLine->chars))
		{
			theLine->info.isCode		=
			theLine->alt->info.isCode	= true;
			theLine->info.address		=
			theLine->alt->info.address	= AddressFromLine(theLine->chars);

			CodeFromLine(theLine);

			strncpy(theLine->alt->info.code, theLine->info.code,
				strlen(theLine->info.code) + 1);

			theLine->info.isFunction		=
			theLine->alt->info.isFunction	= LineIsFunction(theLine);

			CheckThunk(theLine);

			if (theLine->info.isFunction)
			{
				mNumFuncInfos++;

				if (mFuncInfos)
					mFuncInfos	= realloc(mFuncInfos,
						sizeof(FunctionInfo) * mNumFuncInfos);
				else
					mFuncInfos	= malloc(sizeof(FunctionInfo));

				mFuncInfos[mNumFuncInfos - 1]	= (FunctionInfo)
					{theLine->info.address, nil, 0};
			}
		}
		else	// not code...
		{
			if (strstr(theLine->chars,
				"Contents of (__TEXT,__coalesced_text)"))
				mEndOfText	= mCoalTextSect.s.addr + mCoalTextSect.s.size;
			else if (strstr(theLine->chars,
				"Contents of (__TEXT,__textcoal_nt)"))
				mEndOfText	= mCoalTextNTSect.s.addr + mCoalTextNTSect.s.size;
		}

		theLine	= theLine->next;
		progCounter++;
	}

	mEndOfText	= mTextSect.s.addr + mTextSect.s.size;
}

//	processLine:
// ----------------------------------------------------------------------------

- (void)processLine: (Line*)ioLine;
{
	if (!strlen(ioLine->chars))
		return;

	char*	theSearchString			= "Contents of ";
	UInt8	theSearchStringLength	= strlen(theSearchString);

	if (strstr(ioLine->chars, theSearchString))
	{
		char	theTempLine[MAX_LINE_LENGTH]	= {0};

		theTempLine[0]	= '\n';

		strncat(theTempLine, &ioLine->chars[theSearchStringLength],
			strlen(&ioLine->chars[theSearchStringLength]));

		ioLine->length	= strlen(theTempLine);
		strncpy(ioLine->chars, theTempLine, ioLine->length + 1);

		if (strstr(ioLine->chars, "\n(__TEXT,__coalesced_text)"))
		{
			mEndOfText		= mCoalTextSect.s.addr + mCoalTextSect.s.size;
			mLocalOffset	= 0;
		}
		else if (strstr(ioLine->chars, "\n(__TEXT,__textcoal_nt)"))
		{
			mEndOfText		= mCoalTextNTSect.s.addr + mCoalTextNTSect.s.size;
			mLocalOffset	= 0;
		}
	}
	else if (mDemangleCppNames)
	{
		char*	demString	=
			PrepareNameForDemangling(ioLine->chars);

		if (demString)
		{
			char*	cpName	= cplus_demangle(demString, DEMANGLE_OPTS);

			free(demString);

			if (cpName)
			{
				if (strlen(cpName) < MAX_LINE_LENGTH - 1)
				{
					free(ioLine->chars);
					ioLine->length	= strlen(cpName) + 1;

					// cpName is null-terminated but has no '\n'. Allocate
					// space for both.
					ioLine->chars	= malloc(ioLine->length + 2);

					// copy cpName and terminate it.
					strncpy(ioLine->chars, cpName, ioLine->length + 1);

					// add '\n' and terminate it
					strncat(ioLine->chars, "\n", 1);
				}

				free(cpName);
			}
		}
	}
}

//	processCodeLine:
// ----------------------------------------------------------------------------

- (void)processCodeLine: (Line**)ioLine;
{
	if (!ioLine || !(*ioLine) || !((*ioLine)->chars))
	{
		printf("otx: tried to process nil code line\n");
		return;
	}

	ChooseLine(ioLine);

	UInt32	theOrigLength								= (*ioLine)->length;
	char	addrSpaces[MAX_FIELD_SPACING]				= {0};
	char	instSpaces[MAX_FIELD_SPACING]				= {0};
	char	mnemSpaces[MAX_FIELD_SPACING]				= {0};
	char	opSpaces[MAX_FIELD_SPACING]					= {0};
	char	commentSpaces[MAX_FIELD_SPACING]			= {0};
	char	localOffsetString[9]						= {0};
	char	theAddressCString[9]						= {0};
	char	theMnemonicCString[20]						= {0};
	char	theOrigCommentCString[MAX_COMMENT_LENGTH]	= {0};
	char	theCommentCString[MAX_COMMENT_LENGTH]		= {0};
	BOOL	needNewLine									= false;

	mLineOperandsCString[0]	= 0;

	// The address and mnemonic always exist, separated by a tab.
	sscanf((*ioLine)->chars, "%s\t%s", theAddressCString, theMnemonicCString);

	// Any remaining data must be accessed manually.
	UInt16	theSrcMarker		=
		strlen(theAddressCString) + strlen(theMnemonicCString) + 1;
	UInt16	theDestMarker		= 0;

	while (++theSrcMarker < theOrigLength)
	{
		if ((*ioLine)->chars[theSrcMarker] == '\t'	||
			(*ioLine)->chars[theSrcMarker] == '\n')
			break;

		mLineOperandsCString[theDestMarker++] = (*ioLine)->chars[theSrcMarker];
	}

	// Add null terminator, this is a static string.
	mLineOperandsCString[theDestMarker] = 0;
	theDestMarker	= 0;

	while (++theSrcMarker < theOrigLength)
	{
		if ((*ioLine)->chars[theSrcMarker] == '\n')
			break;

		theOrigCommentCString[theDestMarker++] = (*ioLine)->chars[theSrcMarker];
	}

	char*	theCodeCString	= (*ioLine)->info.code;
	SInt16	i				=
		mFieldWidths.instruction - strlen(theCodeCString);

	for (; i > 1; i--)
		mnemSpaces[i - 2]	= 0x20;

	i	= mFieldWidths.mnemonic - strlen(theMnemonicCString);

	for (; i > 1; i--)
		opSpaces[i - 2]	= 0x20;

	// Fill up commentSpaces based on operands field width.
	if (mLineOperandsCString[0] && theOrigCommentCString[0])
	{
		i	= mFieldWidths.operands - strlen(mLineOperandsCString);

		for (; i > 1; i--)
			commentSpaces[i - 2]	= 0x20;
	}

	// Remove "; symbol stub for: "
	if (theOrigCommentCString[0])
	{
		char*	theSubstring	=
			strstr(theOrigCommentCString, "; symbol stub for: ");

		if (theSubstring)
			strncpy(theCommentCString, &theOrigCommentCString[19],
				strlen(&theOrigCommentCString[19]) + 1);
		else
			strncpy(theCommentCString, theOrigCommentCString,
				strlen(theOrigCommentCString) + 1);
	}

	char	theMethCName[1000]	= {0};

	// Check if this is the beginning of a function.
	if ((*ioLine)->info.isFunction)
	{
		// New function, new local offset count.
		mLocalOffset	= 0;
		mCurrentFuncPtr	= (*ioLine)->info.address;

		// Try to build the method name.
		MethodInfo*	theInfo			=
			ObjcMethodFromAddress(mCurrentFuncPtr);

		if (theInfo != nil)
		{
			char*	className	= nil;
			char*	catName		= nil;

			if (theInfo->oc_cat.category_name)
			{
				className	= GetPointer(
					(UInt32)theInfo->oc_cat.class_name, nil);
				catName		= GetPointer(
					(UInt32)theInfo->oc_cat.category_name, nil);
			}
			else if (theInfo->oc_class.name)
			{
				className	= GetPointer(
					(UInt32)theInfo->oc_class.name, nil);
			}

			if (className)
			{
				char*	selName	= GetPointer(
					(UInt32)theInfo->m.method_name, nil);

				if (selName)
				{
					if (!theInfo->m.method_types)
						return;

					char	returnCType[MAX_TYPE_STRING_LENGTH]	= {0};
					char*	methTypes	=
						GetPointer((UInt32)theInfo->m.method_types, nil);

					if (!methTypes)
						return;

					[self decodeMethodReturnType: methTypes
						output: returnCType];

					if (catName)
					{
						char*	methNameFormat	= mShowMethReturnTypes ?
							"\n%1$c(%5$s)[%2$s(%3$s) %4$s]\n" :
							"\n%c[%s(%s) %s]\n";

						snprintf(theMethCName, 1000,
							methNameFormat,
							(theInfo->inst) ? '-' : '+',
							className, catName, selName, returnCType);
					}
					else
					{
						char*	methNameFormat	= mShowMethReturnTypes ?
							"\n%1$c(%4$s)[%2$s %3$s]\n" : "\n%c[%s %s]\n";

						snprintf(theMethCName, 1000,
							methNameFormat,
							(theInfo->inst) ? '-' : '+',
							className, selName, returnCType);
					}
				}
			}
		}	// if (theInfo != nil)

		// Add or replace the method name if possible, else add '\n'.
		if ((*ioLine)->prev && (*ioLine)->prev->info.isCode)	// prev line is code
		{
			if (theMethCName[0])
			{
				Line*	theNewLine	= malloc(sizeof(Line));

				theNewLine->length	= strlen(theMethCName);
				theNewLine->chars	= malloc(theNewLine->length + 1);

				strncpy(theNewLine->chars, theMethCName,
					theNewLine->length + 1);
				InsertLineBefore(theNewLine, *ioLine, &mPlainLineListHead);
			}
			else if ((*ioLine)->info.address == mAddrDyldStubBindingHelper)
			{
				Line*	theNewLine	= malloc(sizeof(Line));
				char*	theDyldName	= "\ndyld_stub_binding_helper:\n";

				theNewLine->length	= strlen(theDyldName);
				theNewLine->chars	= malloc(theNewLine->length + 1);

				strncpy(theNewLine->chars, theDyldName, theNewLine->length + 1);
				InsertLineBefore(theNewLine, *ioLine, &mPlainLineListHead);
			}
			else if ((*ioLine)->info.address == mAddrDyldFuncLookupPointer)
			{
				Line*	theNewLine	= malloc(sizeof(Line));
				char*	theDyldName	= "\n__dyld_func_lookup:\n";

				theNewLine->length	= strlen(theDyldName);
				theNewLine->chars	= malloc(theNewLine->length + 1);

				strncpy(theNewLine->chars, theDyldName, theNewLine->length + 1);
				InsertLineBefore(theNewLine, *ioLine, &mPlainLineListHead);
			}
			else
				needNewLine	= true;
		}
		else	// prev line is not code
		{
			if (theMethCName[0])
			{
				Line*	theNewLine	= malloc(sizeof(Line));

				theNewLine->length	= strlen(theMethCName);
				theNewLine->chars	= malloc(theNewLine->length + 1);

				strncpy(theNewLine->chars, theMethCName,
					theNewLine->length + 1);
				ReplaceLine((*ioLine)->prev, theNewLine, &mPlainLineListHead);
			}
			else	// theMethName sux, add '\n' to otool's method name.
			{
				char	theNewLine[MAX_LINE_LENGTH]	= {0};

				theNewLine[0]	= '\n';

				strncat(theNewLine, (*ioLine)->prev->chars,
					(*ioLine)->prev->length);
				free((*ioLine)->prev->chars);
				(*ioLine)->prev->length	= strlen(theNewLine);
				(*ioLine)->prev->chars	= malloc((*ioLine)->prev->length + 1);
				strncpy((*ioLine)->prev->chars, theNewLine,
					(*ioLine)->prev->length + 1);
			}
		}

		// Clear registers and update current class.
		mCurrentClass	= ObjcClassPtrFromMethod((*ioLine)->info.address);
		mCurrentCat		= ObjcCatPtrFromMethod((*ioLine)->info.address);

		UpdateRegisters(nil);
	}

	// Find a comment if necessary.
	if (!theCommentCString[0])
	{
		CommentForLine(*ioLine);

		UInt32	origCommentLength	= strlen(mLineCommentCString);

		if (origCommentLength)
		{
			char	tempComment[MAX_COMMENT_LENGTH]	= {0};
			UInt32	i, j= 0;

			for (i = 0; i < origCommentLength; i++)
			{
				if (mLineCommentCString[i] == '\n')
				{
					tempComment[j++]	= '\\';
					tempComment[j++]	= 'n';
				}
				else if (mLineCommentCString[i] == '\r')
				{
					tempComment[j++]	= '\\';
					tempComment[j++]	= 'r';
				}
				else if (mLineCommentCString[i] == '\t')
				{
					tempComment[j++]	= '\\';
					tempComment[j++]	= 't';
				}
				else
					tempComment[j++]	= mLineCommentCString[i];
			}

			if (mLineOperandsCString[0])
				strncpy(theCommentCString, tempComment,
					strlen(tempComment) + 1);
			else
				strncpy(mLineOperandsCString, tempComment,
					strlen(tempComment) + 1);

			// Fill up commentSpaces based on operands field width.
			SInt32	k	= mFieldWidths.operands - strlen(mLineOperandsCString);

			for (; k > 1; k--)
				commentSpaces[k - 2]	= 0x20;
		}
	}

	// Demangle operands if necessary.
	if (mLineOperandsCString[0] && mDemangleCppNames)
	{
		char*	demString	=
			PrepareNameForDemangling(mLineOperandsCString);

		if (demString)
		{
			char*	cpName	= cplus_demangle(demString, DEMANGLE_OPTS);

			free(demString);

			if (cpName)
			{
				if (strlen(cpName) < MAX_OPERANDS_LENGTH - 1)
				{
					bzero(mLineOperandsCString, strlen(mLineOperandsCString));
					strncpy(mLineOperandsCString, cpName, strlen(cpName) + 1);
				}

				free(cpName);
			}
		}
	}

	// Demangle comment if necessary.
	if (theCommentCString[0] && mDemangleCppNames)
	{
		char*	demString	=
			PrepareNameForDemangling(theCommentCString);

		if (demString)
		{
			char*	cpName	= cplus_demangle(demString, DEMANGLE_OPTS);

			free(demString);

			if (cpName)
			{
				if (strlen(cpName) < MAX_COMMENT_LENGTH - 1)
				{
					bzero(theCommentCString, strlen(theCommentCString));
					strncpy(theCommentCString, cpName, strlen(cpName) + 1);
				}

				free(cpName);
			}
		}
	}

	// Optionally add local offset.
	if (mShowLocalOffsets)
	{
		// Build a right-aligned string  with a '+' in it.
		snprintf((char*)&localOffsetString, mFieldWidths.offset,
			"%6lu", mLocalOffset);

		// Find the space that's followed by a nonspace.
		// *Reverse count to optimize for short functions.
		for (i = 0; i < 5; i++)
		{
			if (localOffsetString[i] == 0x20 &&
				localOffsetString[i + 1] != 0x20)
			{
				localOffsetString[i] = '+';
				break;
			}
		}

		if (theCodeCString)
			mLocalOffset += strlen(theCodeCString) / 2;

		// Fill up addrSpaces based on offset field width.
		i	= mFieldWidths.offset - 6;

		for (; i > 1; i--)
			addrSpaces[i - 2] = 0x20;
	}

	// Fill up instSpaces based on address field width.
	i	= mFieldWidths.address - 8;

	for (; i > 1; i--)
		instSpaces[i - 2] = 0x20;

	// Finally, assemble the new string.
	char	finalFormatCString[MAX_FORMAT_LENGTH]	= {0};
	UInt32	formatMarker	= 0;

	bzero(finalFormatCString, MAX_FORMAT_LENGTH);

	if (needNewLine)
		finalFormatCString[formatMarker++]	= '\n';

	if (mShowLocalOffsets)
		formatMarker += snprintf(&finalFormatCString[formatMarker],
			10, "%s", "%s %s");

	if (mLineOperandsCString[0])
	{
		if (theCommentCString[0])
			snprintf(&finalFormatCString[formatMarker],
				30, "%s", "%s %s%s %s%s %s%s %s%s\n");
		else
			snprintf(&finalFormatCString[formatMarker],
				30, "%s", "%s %s%s %s%s %s%s\n");
	}
	else
		snprintf(&finalFormatCString[formatMarker],
			30, "%s", "%s %s%s %s%s\n");

	char	theFinalCString[MAX_LINE_LENGTH]	/*= {0}*/;

	if (mShowLocalOffsets)
		snprintf(theFinalCString, MAX_LINE_LENGTH - 1,
			finalFormatCString, localOffsetString,
			addrSpaces, theAddressCString,
			instSpaces, theCodeCString,
			mnemSpaces, theMnemonicCString,
			opSpaces, mLineOperandsCString,
			commentSpaces, theCommentCString);
	else
		snprintf(theFinalCString, MAX_LINE_LENGTH - 1,
			finalFormatCString, theAddressCString,
			instSpaces, theCodeCString,
			mnemSpaces, theMnemonicCString,
			opSpaces, mLineOperandsCString,
			commentSpaces, theCommentCString);

	free((*ioLine)->chars);
	(*ioLine)->length	= strlen(theFinalCString);
	(*ioLine)->chars	= malloc((*ioLine)->length + 1);
	strncpy((*ioLine)->chars, theFinalCString, (*ioLine)->length + 1);

	UpdateRegisters(*ioLine);
	PostProcessCodeLine(ioLine);
}

//	postProcessCodeLine:
// ----------------------------------------------------------------------------
//	Subclasses may override.

- (void)postProcessCodeLine: (Line**)ioLine
{}

//	printDataSections
// ----------------------------------------------------------------------------
//	Append data sections to output file.

- (BOOL)printDataSections
{
	const char*	outPath		= CSTRING(mOutputFilePath);
	FILE*		outFile		= fopen(outPath, "a");

	if (!outFile)
	{
		perror("otx: unable to open output file");
		return false;
	}

	if (mDataSect.size)
	{
		if (fprintf(outFile, "\n(__DATA,__data) section\n") < 0)
		{
			perror("otx: unable to write to output file");
			return false;
		}

		[self printDataSection: &mDataSect toFile: outFile];
	}

	if (mCoalDataSect.size)
	{
		if (fprintf(outFile, "\n(__DATA,__coalesced_data) section\n") < 0)
		{
			perror("otx: unable to write to output file");
			return false;
		}

		[self printDataSection: &mCoalDataSect toFile: outFile];
	}

	if (mCoalDataNTSect.size)
	{
		if (fprintf(outFile, "\n(__DATA,__datacoal_nt) section\n") < 0)
		{
			perror("otx: unable to write to output file");
			return false;
		}

		[self printDataSection: &mCoalDataNTSect toFile: outFile];
	}

	if (fclose(outFile) != 0)
	{
		perror("otx: unable to close output file");
		return false;
	}

	return true;
}

//	printDataSection:toFile:
// ----------------------------------------------------------------------------

- (void)printDataSection: (section_info*)inSect
				  toFile: (FILE*)outFile;
{
	UInt32	i, j, k, bytesLeft;
	UInt32	theDataSize			= inSect->size;
	char	theLineCString[70]	= {0};
	char*	theMachPtr			= (char*)mMachHeader;

	for (i = 0; i < theDataSize; i += 16)
	{
		bytesLeft	= theDataSize - i;

		if (bytesLeft < 16)	// last line
		{
			bzero(theLineCString, sizeof(theLineCString));
			snprintf(theLineCString,
				20 ,"%08x |", inSect->s.addr + i);

			unsigned char	theHexData[17]		= {0};
			unsigned char	theASCIIData[17]	= {0};

			memcpy(theHexData,
				(const void*)(theMachPtr + inSect->s.offset + i), bytesLeft);
			memcpy(theASCIIData,
				(const void*)(theMachPtr + inSect->s.offset + i), bytesLeft);

			j	= 10;

			for (k = 0; k < bytesLeft; k++)
			{
				if (!(k % 4))
					theLineCString[j++]	= 0x20;

				snprintf(&theLineCString[j], 4, "%02x", theHexData[k]);
				j += 2;

				if (theASCIIData[k] < 0x20 || theASCIIData[k] == 0x7f)
					theASCIIData[k]	= '.';
			}

			// Append spaces.
			for (; j < 48; j++)
				theLineCString[j]	= 0x20;

			// Append ASCII chars.
			snprintf(&theLineCString[j], 70, "%s\n", theASCIIData);
		}
		else	// first lines
		{			
			UInt32*			theHexPtr			= (UInt32*)
				(theMachPtr + inSect->s.offset + i);
			unsigned char	theASCIIData[17]	= {0};
			UInt8			j;

			memcpy(theASCIIData,
				(const void*)(theMachPtr + inSect->s.offset + i), 16);

			for (j = 0; j < 16; j++)
				if (theASCIIData[j] < 0x20 || theASCIIData[j] == 0x7f)
					theASCIIData[j]	= '.';

			if (OSHostByteOrder() == OSLittleEndian)
			{
				theHexPtr[0]	= OSSwapInt32(theHexPtr[0]);
				theHexPtr[1]	= OSSwapInt32(theHexPtr[1]);
				theHexPtr[2]	= OSSwapInt32(theHexPtr[2]);
				theHexPtr[3]	= OSSwapInt32(theHexPtr[3]);
			}

			snprintf(theLineCString, sizeof(theLineCString),
				"%08x | %08x %08x %08x %08x  %s\n",
				inSect->s.addr + i,
				theHexPtr[0], theHexPtr[1], theHexPtr[2], theHexPtr[3],
				theASCIIData);
		}

		if (fprintf(outFile, "%s", theLineCString) < 0)
		{
			perror("otx: unable to write to output file");
			return;
		}
	}
}

//	lineIsCode:
// ----------------------------------------------------------------------------
//	Line is code if first 8 chars are hex numbers and 9th is tab.

- (BOOL)lineIsCode: (const char*)inLine
{
	if (strlen(inLine) < 10)
		return false;

	UInt16	i;

	for (i = 0 ; i < 8; i++)
	{
		if ((inLine[i] < '0' || inLine[i] > '9') &&
			(inLine[i] < 'a' || inLine[i] > 'f'))
			return  false;
	}

	return (inLine[8] == '\t');
}

//	addressFromLine:
// ----------------------------------------------------------------------------

- (UInt32)addressFromLine: (const char*)inLine
{
	// sanity check
	if ((inLine[0] < '0' || inLine[0] > '9') &&
		(inLine[0] < 'a' || inLine[0] > 'f'))
		return 0;

	UInt32	theAddress	= 0;

	sscanf(inLine, "%08x", &theAddress);
	return theAddress;
}

//	lineIsFunction:
// ----------------------------------------------------------------------------
//	Subclasses may override

- (BOOL)lineIsFunction: (Line*)inLine
{
	return false;
}

//	codeFromLine:
// ----------------------------------------------------------------------------
//	Subclasses must override.

- (void)codeFromLine: (Line*)inLine
{}

//	checkThunk:
// ----------------------------------------------------------------------------
//	Subclasses may override.

- (void)checkThunk:(Line*)inLine
{}

//	commentForLine:
// ----------------------------------------------------------------------------
//	Subclasses may override.

- (void)commentForLine: (Line*)inLine
{}

//	commentForSystemCall
// ----------------------------------------------------------------------------
//	Subclasses may override.

- (void)commentForSystemCall
{}

//	chooseLine:
// ----------------------------------------------------------------------------
//	Subclasses may override.

- (void)chooseLine: (Line**)ioLine
{}

//	updateRegisters:
// ----------------------------------------------------------------------------
//	Subclasses may override.

- (void)updateRegisters: (Line*)inLine
{}

//	insertMD5
// ----------------------------------------------------------------------------

- (void)insertMD5
{
	char		md5Line[MAX_MD5_LINE];
	char		finalLine[MAX_MD5_LINE];
	NSString*	md5CommandString	= [NSString stringWithFormat:
		@"md5 -q '%@'", [mOFile path]];
	FILE*		md5Pipe				= popen(CSTRING(md5CommandString), "r");

	if (!md5Pipe)
	{
		printf("otx: unable to open md5 pipe\n");
		return;
	}

	if (!fgets(md5Line, MAX_MD5_LINE, md5Pipe))
	{
		perror("otx: unable to read from md5 pipe");
		return;
	}

	if (pclose(md5Pipe) == -1)
	{
		printf("otx: error closing md5 pipe\n");
		return;
	}

	strncpy(finalLine, "\nmd5: ", 7);
	strncat(finalLine, md5Line, strlen(md5Line));
	strncat(finalLine, "\n", 1);

	Line*	newLine	= malloc(sizeof(Line));

	bzero(newLine, sizeof(Line));

	newLine->length	= strlen(finalLine);
	newLine->chars	= malloc(newLine->length + 1);
	strncpy(newLine->chars, finalLine, newLine->length + 1);

	InsertLineAfter(newLine, mPlainLineListHead, &mPlainLineListHead);
}

//	prepareNameForDemangling:
// ----------------------------------------------------------------------------
//	For cplus_demangle(), we must remove any extra leading underscores and
//	any trailing colons. Caller owns the returned string.

- (char*)prepareNameForDemangling: (char*)inName
{
	char*	preparedName	= nil;

	// Bail if 1st char is not '_'.
	if (strchr(inName, '_') != inName)
		return nil;

	// Find start of mangled name or bail.
	char*	symString	= strstr(inName, "_Z");

	if (!symString)
		return nil;

	// Find trailing colon.
	UInt32	newSize		= strlen(symString);
	char*	colonPos	= strrchr(symString, ':');

	// Perform colonoscopy.
	if (colonPos)
		newSize	= colonPos - symString;

	// Copy adjusted symbol into new string.
	preparedName	= malloc(newSize + 1);

	bzero(preparedName, newSize + 1);
	strncpy(preparedName, symString, newSize);

	return preparedName;
}

#pragma mark -
//	objcClassPtrFromMethod:
// ----------------------------------------------------------------------------
//	Given a method imp address, return the class to which it belongs. This func
//	is called each time a new function is detected. If that function is known
//	to be an Obj-C method, it's class is returned. Otherwise this returns nil.

- (objc_class*)objcClassPtrFromMethod: (UInt32)inAddress;
{
	MethodInfo*	theInfo	= nil;

	FindClassMethodByAddress(&theInfo, inAddress);

	if (theInfo)
		return &theInfo->oc_class;

	return nil;
}

//	objcCatPtrFromMethod:
// ----------------------------------------------------------------------------
//	Same as above, for categories.

- (objc_category*)objcCatPtrFromMethod: (UInt32)inAddress;
{
	MethodInfo*	theInfo	= nil;

	FindCatMethodByAddress(&theInfo, inAddress);

	if (theInfo)
		return &theInfo->oc_cat;

	return nil;
}

//	objcMethodFromAddress:
// ----------------------------------------------------------------------------
//	Given a method imp address, return the MethodInfo for it.

- (MethodInfo*)objcMethodFromAddress: (UInt32)inAddress;
{
	MethodInfo*	theInfo	= nil;

	FindClassMethodByAddress(&theInfo, inAddress);

	if (theInfo)
		return theInfo;

	FindCatMethodByAddress(&theInfo, inAddress);

	return theInfo;
}

//	objcClass:fromName:
// ----------------------------------------------------------------------------
//	Given a class name, return the class itself. This func is used to tie
//	categories to classes. We have 2 pointers to the same name, so pointer
//	equality is sufficient.

- (BOOL)objcClass: (objc_class*)outClass
		 fromName: (const char*)inName;
{
	UInt32	i;

	for (i = 0; i < mNumClassMethodInfos; i++)
	{
		if (GetPointer((UInt32)mClassMethodInfos[i].oc_class.name,
			nil) == inName)
		{
			*outClass	= mClassMethodInfos[i].oc_class;
			return true;
		}
	}

	*outClass	= (objc_class){0};

	return false;
}

//	objcDescriptionFromObject:type:
// ----------------------------------------------------------------------------
//	Given an Obj-C object, return it's description.

- (char*)objcDescriptionFromObject: (const char*)inObject
							  type: (UInt8)inType
{
	char*	thePtr		= nil;
	UInt32	theValue	= 0;

	switch (inType)
	{
		case OCStrObjectType:
		{
			objc_string_object	ocString	= *(objc_string_object*)inObject;

			if (ocString.length == 0)
				break;

			theValue	= (UInt32)ocString.chars;

			break;
		}
		case OCClassType:
		{
			objc_class	ocClass	= *(objc_class*)inObject;

			theValue	= (ocClass.name != 0) ?
				(UInt32)ocClass.name : (UInt32)ocClass.isa;

			break;
		}
		case OCModType:
		{
			objc_module	ocMod	= *(objc_module*)inObject;

			theValue	= (UInt32)ocMod.name;

			break;
		}
		case OCGenericType:
			theValue	= *(UInt32*)inObject;

			break;

		default:
			break;
	}

	if (mSwapped)
		theValue	= OSSwapInt32(theValue);

	thePtr	= GetPointer(theValue, nil);

	return thePtr;
}

#pragma mark -
//	decodeMethodReturnType:output:
// ----------------------------------------------------------------------------

- (void)decodeMethodReturnType: (const char*)inTypeCode
						output: (char*)outCString
{
	UInt32	theNextChar	= 0;

	// Check for type specifiers.
	// r* <-> const char* ... VI <-> oneway unsigned int
	switch (inTypeCode[theNextChar++])
	{
		case 'r':
			strncpy(outCString, "const ", 7);
			break;
		case 'n':
			strncpy(outCString, "in ", 4);
			break;
		case 'N':
			strncpy(outCString, "inout ", 7);
			break;
		case 'o':
			strncpy(outCString, "out ", 5);
			break;
		case 'O':
			strncpy(outCString, "bycopy ", 8);
			break;
		case 'V':
			strncpy(outCString, "oneway ", 8);
			break;

		// No specifier found, roll back the marker.
		default:
			theNextChar--;
			break;
	}

	GetDescription(outCString, &inTypeCode[theNextChar]);
}

//	getDescription:forType:
// ----------------------------------------------------------------------------
//	"filer types" defined in objc/objc-class.h, NSCoder.h, and
// http://developer.apple.com/documentation/DeveloperTools/gcc-3.3/gcc/Type-encoding.html

- (void)getDescription: (char*)ioCString
			   forType: (const char*)inTypeCode
{
	if (!inTypeCode || !ioCString)
		return;

	char	theSuffixCString[50]	= {0};
	UInt32	theNextChar				= 0;
	UInt16	i						= 0;

/*
	char vs. BOOL

	data type		encoding
	���������		��������
	BOOL			c
	char			c
	BOOL[100]		[100c]
	char[100]		[100c]

	Any occurence of 'c' may be a char or a BOOL. The best option I can see is
	to treat arrays as char arrays and atomic values as BOOL, and maybe let
	the user disagree via preferences. Since the data type of an array is
	decoded with a recursive call, we can use the following static variable
	for this purpose.

	As of otx 0.14b, letting the user override this behavior with a pref
	is left as an exercise for the reader.
*/
	static	BOOL	isArray	= false;

	// Convert '^^' prefix to '**' suffix.
	while (inTypeCode[theNextChar] == '^')
	{
		theSuffixCString[i++]	= '*';
		theNextChar++;
	}

	i	= 0;

	char	theTypeCString[MAX_TYPE_STRING_LENGTH]	= {0};

	// Now we can get at the basic type.
	switch (inTypeCode[theNextChar])
	{
		case '@':
		{
			if (inTypeCode[theNextChar + 1] == '"')
			{
				UInt32	classNameLength	=
					strlen(&inTypeCode[theNextChar + 2]);

				memcpy(theTypeCString, &inTypeCode[theNextChar + 2],
					classNameLength - 1);
			}
			else
				strncpy(theTypeCString, "id", 3);

			break;
		}

		case '#':
			strncpy(theTypeCString, "Class", 6);
			break;
		case ':':
			strncpy(theTypeCString, "SEL", 4);
			break;
		case '*':
			strncpy(theTypeCString, "char*", 6);
			break;
		case '?':
			strncpy(theTypeCString, "undefined", 10);
			break;
		case 'i':
			strncpy(theTypeCString, "int", 4);
			break;
		case 'I':
			strncpy(theTypeCString, "unsigned int", 13);
			break;
		// bitfield according to objc-class.h, C++ bool according to NSCoder.h.
		// The above URL expands on obj-class.h's definition of 'b' when used
		// in structs/unions, but NSCoder.h's definition seems to take
		// priority in return values.
		case 'B':
		case 'b':
			strncpy(theTypeCString, "bool", 5);
			break;
		case 'c':
			strncpy(theTypeCString, (isArray) ? "char" : "BOOL", 5);
			break;
		case 'C':
			strncpy(theTypeCString, "unsigned char", 14);
			break;
		case 'd':
			strncpy(theTypeCString, "double", 7);
			break;
		case 'f':
			strncpy(theTypeCString, "float", 6);
			break;
		case 'l':
			strncpy(theTypeCString, "long", 5);
			break;
		case 'L':
			strncpy(theTypeCString, "unsigned long", 14);
			break;
		case 'q':	// not in objc-class.h
			strncpy(theTypeCString, "long long", 10);
			break;
		case 'Q':	// not in objc-class.h
			strncpy(theTypeCString, "unsigned long long", 19);
			break;
		case 's':
			strncpy(theTypeCString, "short", 6);
			break;
		case 'S':
			strncpy(theTypeCString, "unsigned short", 15);
			break;
		case 'v':
			strncpy(theTypeCString, "void", 5);
			break;
		case '(':	// union- just copy the name
			while (inTypeCode[++theNextChar] != '=' &&
				   inTypeCode[theNextChar]   != ')'	&&
				   inTypeCode[theNextChar]   != '<'	&&
				   theNextChar < MAX_TYPE_STRING_LENGTH)
				theTypeCString[i++]	= inTypeCode[theNextChar];

			break;

		case '{':	// struct- just copy the name
			while (inTypeCode[++theNextChar] != '='	&&
				   inTypeCode[theNextChar]   != '}'	&&
				   inTypeCode[theNextChar]   != '<'	&&
				   theNextChar < MAX_TYPE_STRING_LENGTH)
				theTypeCString[i++]	= inTypeCode[theNextChar];

			break;

		case '[':	// array�	[12^f] <-> float*[12]
		{
			char	theArrayCCount[10]	= {0};

			while (inTypeCode[++theNextChar] >= '0' &&
				   inTypeCode[theNextChar]   <= '9')
				theArrayCCount[i++]	= inTypeCode[theNextChar];

			// Recursive madness. See 'char vs. BOOL' note above.
			char	theCType[MAX_TYPE_STRING_LENGTH]	= {0};

			isArray	= true;
			GetDescription(theCType, &inTypeCode[theNextChar]);
			isArray	= false;

			snprintf(theTypeCString, MAX_TYPE_STRING_LENGTH + 1, "%s[%s]",
				theCType, theArrayCCount);

			break;
		}

		default:
			strncpy(theTypeCString, "?", 2);
			printf("otx: unknown encoded type: %c\n", inTypeCode[theNextChar]);

			break;
	}

	strncat(ioCString, theTypeCString, strlen(theTypeCString));

	if (theSuffixCString[0])
		strncat(ioCString, theSuffixCString, strlen(theSuffixCString));
}

#pragma mark -
//	entabLine:
// ----------------------------------------------------------------------------
//	A cheap and fast way to entab a line, assuming it contains no tabs already.
//	If tabs get added in the future, this WILL break. Single spaces are not
//	replaced with tabs, even when possible, since it would save no additional
//	bytes.

- (void)entabLine: (Line*)ioLine;
{
	if (!ioLine || !ioLine->chars)
		return;

	UInt32	i;			// oldLine marker
	UInt32	j	= 0;	// newLine marker

	char	entabbedLine[MAX_LINE_LENGTH]	= {0};
	UInt32	theOrigLength					= ioLine->length;

	// If 1st char is '\n', skip it.
	UInt32	firstChar	= (ioLine->chars[0] == '\n');

	if (firstChar)
		entabbedLine[j++]	= '\n';

	// Inspect 4 bytes at a time.
	for (i = firstChar; i < theOrigLength; i += 4)
	{
		// If fewer than 4 bytes remain, adding any tabs is pointless.
		if (i > theOrigLength - 4)
		{	// copy the remainder and split.
			while (i < theOrigLength)
				entabbedLine[j++] = ioLine->chars[i++];

			break;
		}

		// If the 4th char is not a space, the first 3 chars don't matter.
		if (ioLine->chars[i + 3] == 0x20)	// 4th char is a space...
		{
			if (ioLine->chars[i + 2] == 0x20)	// 3rd char is a space...
			{
				if (ioLine->chars[i + 1] == 0x20)	// 2nd char is a space...
				{
					if (ioLine->chars[i] == 0x20)	// all 4 chars are spaces!
						entabbedLine[j++] = '\t';	// write a tab and split
					else	// only the 1st char is not a space
					{		// write 1st char and tab
						entabbedLine[j++] = ioLine->chars[i];
						entabbedLine[j++] = '\t';
					}
				}
				else	// 2nd char is not a space
				{		// write 1st 2 chars and tab
					entabbedLine[j++] = ioLine->chars[i];
					entabbedLine[j++] = ioLine->chars[i + 1];
					entabbedLine[j++] = '\t';
				}
			}
			else	// 3rd char is not a space
			{		// copy all 4 chars
				memcpy(&entabbedLine[j], &ioLine->chars[i], 4);
				j += 4;
			}
		}
		else	// 4th char is not a space
		{		// copy all 4 chars
			memcpy(&entabbedLine[j], &ioLine->chars[i], 4);
			j += 4;
		}
	}

	// Replace the old C string with the new one.
	free(ioLine->chars);
	ioLine->length	= strlen(entabbedLine);
	ioLine->chars	= malloc(ioLine->length + 1);
	strncpy(ioLine->chars, entabbedLine, ioLine->length + 1);
}

#pragma mark -
#pragma mark Binary searches

//	findSymbolByAddress:
// ----------------------------------------------------------------------------

- (BOOL)findSymbolByAddress: (UInt32)inAddress
{
	if (!mFuncSyms)
		return false;

	nlist*	searchKey	= malloc(sizeof(nlist));

	searchKey->n_value	= inAddress;

	BOOL	symbolExists	= (bsearch(&searchKey,
		mFuncSyms, mNumFuncSyms, sizeof(nlist*),
		(int (*)(const void*, const void*))sym_compare) != nil);

	free(searchKey);

	return symbolExists;
}

//	findClassMethod:byAddress:
// ----------------------------------------------------------------------------

- (BOOL)findClassMethod: (MethodInfo**)outMI
			  byAddress: (UInt32)inAddress;
{
	if (!outMI)
		return false;

	if (!mClassMethodInfos)
	{
		*outMI	= nil;
		return false;
	}

	MethodInfo	searchKey	= {{nil, nil, (IMP)inAddress}, {0}, {0}, false};

	*outMI	= bsearch(&searchKey,
		mClassMethodInfos, mNumClassMethodInfos, sizeof(MethodInfo),
		(int (*)(const void*, const void*))methodInfo_compare);

	return (*outMI != nil);
}

//	findCatMethod:byAddress:
// ----------------------------------------------------------------------------

- (BOOL)findCatMethod: (MethodInfo**)outMI
			byAddress: (UInt32)inAddress;
{
	if (!outMI)
		return false;

	if (!mCatMethodInfos)
	{
		*outMI	= nil;
		return false;
	}

	MethodInfo	searchKey	= {{nil, nil, (IMP)inAddress}, {0}, {0}, false};

	*outMI	= bsearch(&searchKey,
		mCatMethodInfos, mNumCatMethodInfos, sizeof(MethodInfo),
		(int (*)(const void*, const void*))methodInfo_compare);

	return (*outMI != nil);
}

//	findIvar:inClass:withOffset:
// ----------------------------------------------------------------------------

- (BOOL)findIvar: (objc_ivar*)outIvar
		 inClass: (objc_class*)inClass
	  withOffset: (UInt32)inOffset
{
	if (!inClass || !outIvar)
		return false;

	// Loop thru inClass and all superclasses.
	objc_class*	theClassPtr		= inClass;
	objc_class	theDummyClass	= {0};
	char*		theSuperName	= nil;

	while (theClassPtr)
	{
		objc_ivar_list*	theIvars	= (objc_ivar_list*)
			GetPointer((UInt32)theClassPtr->ivars, nil);

		if (!theIvars)
		{	// Try again with the superclass.
			theSuperName	= GetPointer(
				(UInt32)theClassPtr->super_class, nil);

			if (!theSuperName)
				break;

			if (!ObjcClassFromName(&theDummyClass, theSuperName))
				break;

			theClassPtr	= &theDummyClass;

			continue;
		}

		UInt32	numIvars	= theIvars->ivar_count;

		if (mSwapped)
			numIvars	= OSSwapInt32(numIvars);

		// It would be nice to use bsearch(3) here, but there's too much
		// swapping.
		SInt64	begin	= 0;
		SInt64	end		= numIvars - 1;
		SInt64	split	= numIvars / 2;
		UInt32	offset;

		while (end >= begin)
		{
			offset	= theIvars->ivar_list[split].ivar_offset;

			if (mSwapped)
				offset	= OSSwapInt32(offset);

			if (offset == inOffset)
			{
				*outIvar	= theIvars->ivar_list[split];

				if (mSwapped)
					swap_objc_ivar(outIvar);

				return true;
			}

			if (offset > inOffset)
				end		= split - 1;
			else
				begin	= split + 1;

			split	= (begin + end) / 2;
		}

		// Try again with the superclass.
		theSuperName	= GetPointer((UInt32)theClassPtr->super_class, nil);

		if (!theSuperName)
			break;

		if (!ObjcClassFromName(&theDummyClass, theSuperName))
			break;

		theClassPtr	= &theDummyClass;
	}

	return false;
}

#pragma mark -
#pragma mark Stolen
// The getXXX methods were originally defined in
// cctools-590/otool/print_objc.c. These adaptations make use of member
// variables.

//	getObjcSymtab:andDefs:fromModule: (was get_symtab)
// ----------------------------------------------------------------------------
//	Removed the truncation flag. 'left' is no longer used by the caller.

- (BOOL)getObjcSymtab: (objc_symtab*)outSymTab
			  andDefs: (void***)outDefs
		   fromModule: (objc_module*)inModule;
{
	unsigned long	addr	= (unsigned long)inModule->symtab;
	unsigned long	i, left;

	bzero(outSymTab, sizeof(objc_symtab));

	for (i = 0; i < mNumObjcSects; i++)
	{
		if (addr >= mObjcSects[i].s.addr &&
			addr < mObjcSects[i].s.addr + mObjcSects[i].size)
		{
			left = mObjcSects[i].size -
				(addr - mObjcSects[i].s.addr);

			if (left >= sizeof(objc_symtab) - sizeof(void*))
			{
				memcpy(outSymTab, mObjcSects[i].contents +
					(addr - mObjcSects[i].s.addr),
					sizeof(objc_symtab) - sizeof(void*));
				left		-= sizeof(objc_symtab) - sizeof(void*);
				*outDefs	= (void**)(mObjcSects[i].contents +
					(addr - mObjcSects[i].s.addr) +
					sizeof(objc_symtab) - sizeof(void*));
			}
			else
			{
				memcpy(outSymTab, mObjcSects[i].contents +
					(addr - mObjcSects[i].s.addr), left);
				*outDefs	= nil;
			}

			if (mSwapped)
				swap_objc_symtab(outSymTab);

			return true;
		}
	}

	return false;
}

//	getObjcClass:fromDef: (was get_objc_class)
// ----------------------------------------------------------------------------

- (BOOL)getObjcClass: (objc_class*)outClass
			 fromDef: (UInt32)inDef;
{
	UInt32	i;

	for (i = 0; i < mNumObjcSects; i++)
	{
		if (inDef >= mObjcSects[i].s.addr &&
			inDef < mObjcSects[i].s.addr + mObjcSects[i].size)
		{
			*outClass	= *(objc_class*)(mObjcSects[i].contents +
				(inDef - mObjcSects[i].s.addr));

			if (mSwapped)
				swap_objc_class(outClass);

			return true;
		}
	}

	return false;
}

//	getObjcCategory:fromDef: (was get_objc_category)
// ----------------------------------------------------------------------------

- (BOOL)getObjcCategory: (objc_category*)outCat
				fromDef: (UInt32)inDef;
{
	UInt32	i;

	for (i = 0; i < mNumObjcSects; i++)
	{
		if (inDef >= mObjcSects[i].s.addr &&
			inDef < mObjcSects[i].s.addr + mObjcSects[i].size)
		{
			*outCat	= *(objc_category*)(mObjcSects[i].contents +
				(inDef - mObjcSects[i].s.addr));

			if (mSwapped)
				swap_objc_category(outCat);

			return true;
		}
	}

	return false;
}

//	getObjcMetaClass:fromClass:
// ----------------------------------------------------------------------------

- (BOOL)getObjcMetaClass: (objc_class*)outClass
			   fromClass: (objc_class*)inClass;
{
	if ((UInt32)inClass->isa >= mMetaClassSect.s.addr &&
		(UInt32)inClass->isa < mMetaClassSect.s.addr + mMetaClassSect.size)
	{
		*outClass	= *(objc_class*)(mMetaClassSect.contents +
			((UInt32)inClass->isa - mMetaClassSect.s.addr));

		if (mSwapped)
			swap_objc_class(outClass);

		return true;
	}

	return false;
}

//	getObjcMethodList:andMethods:fromAddress: (was get_method_list)
// ----------------------------------------------------------------------------
//	Removed the truncation flag. 'left' is no longer used by the caller.

- (BOOL)getObjcMethodList: (objc_method_list*)outList
			   andMethods: (objc_method**)outMethods
			  fromAddress: (UInt32)inAddress;
{
	UInt32	left, i;

	bzero(outList, sizeof(objc_method_list));

	for (i = 0; i < mNumObjcSects; i++)
	{
		if (inAddress >= mObjcSects[i].s.addr &&
			inAddress < mObjcSects[i].s.addr + mObjcSects[i].size)
		{
			left = mObjcSects[i].size -
				(inAddress - mObjcSects[i].s.addr);

			if (left >= sizeof(objc_method_list) -
				sizeof(objc_method))
			{
				memcpy(outList, mObjcSects[i].contents +
					(inAddress - mObjcSects[i].s.addr),
					sizeof(objc_method_list) - sizeof(objc_method));
				left -= sizeof(objc_method_list) -
					sizeof(objc_method);
				*outMethods = (objc_method*)(mObjcSects[i].contents +
					(inAddress - mObjcSects[i].s.addr) +
					sizeof(objc_method_list) - sizeof(objc_method));
			}
			else
			{
				memcpy(outList, mObjcSects[i].contents +
					(inAddress - mObjcSects[i].s.addr), left);
				left = 0;
				*outMethods = nil;
			}

			if (mSwapped)
				swap_objc_method_list(outList);

			return true;
		}
	}

	return false;
}

//	getPointer:outType:	(was get_pointer)
// ----------------------------------------------------------------------------
//	Convert a relative ptr to an absolute ptr. Return which data type is being
//	referenced in outType.

- (char*)getPointer: (UInt32)inAddr
			andType: (UInt8*)outType
{
	if (inAddr == 0)
		return nil;

	if (outType)
		*outType	= PointerType;

	char*	thePtr	= nil;
	UInt32	i;

			// (__TEXT,__cstring) (char*)
	if (inAddr >= mCStringSect.s.addr &&
		inAddr < mCStringSect.s.addr + mCStringSect.size)
	{
		thePtr = (mCStringSect.contents + (inAddr - mCStringSect.s.addr));

		// Make sure we're pointing to the beginning of a string,
		// not somewhere in the middle.
		if (*(thePtr - 1) != 0 && inAddr != mCStringSect.s.addr)
			thePtr	= nil;
	}
	else	// (__TEXT,__const) (Str255* sometimes)
	if (inAddr >= mConstTextSect.s.addr &&
		inAddr < mConstTextSect.s.addr + mConstTextSect.size)
	{
		thePtr	= (mConstTextSect.contents + (inAddr - mConstTextSect.s.addr));

		if (strlen(thePtr) == thePtr[0] + 1 && outType)
			*outType	= PStringType;
		else
			thePtr	= nil;
	}
	else	// (__TEXT,__literal4) (float)
	if (inAddr >= mLit4Sect.s.addr &&
		inAddr < mLit4Sect.s.addr + mLit4Sect.size)
	{
		thePtr	= (char*)((UInt32)mLit4Sect.contents +
			(inAddr - mLit4Sect.s.addr));

		if (outType)
			*outType	= FloatType;
	}
	else	// (__TEXT,__literal8) (double)
	if (inAddr >= mLit8Sect.s.addr &&
		inAddr < mLit8Sect.s.addr + mLit8Sect.size)
	{
		thePtr	= (char*)((UInt32)mLit8Sect.contents +
			(inAddr - mLit8Sect.s.addr));

		if (outType)
			*outType	= DoubleType;
	}

	if (thePtr)
		return thePtr;

			// (__OBJC,__cstring_object) (objc_string_object)
	if (inAddr >= mNSStringSect.s.addr &&
		inAddr < mNSStringSect.s.addr + mNSStringSect.size)
	{
		thePtr	= (char*)((UInt32)mNSStringSect.contents +
			(inAddr - mNSStringSect.s.addr));

		if (outType)
			*outType	= OCStrObjectType;
	}
	else	// (__OBJC,__class) (objc_class)
	if (inAddr >= mClassSect.s.addr &&
		inAddr < mClassSect.s.addr + mClassSect.size)
	{
		thePtr	= (char*)((UInt32)mClassSect.contents +
			(inAddr - mClassSect.s.addr));

		if (outType)
			*outType	= OCClassType;
	}
	else	// (__OBJC,__meta_class) (objc_class)
	if (inAddr >= mMetaClassSect.s.addr &&
		inAddr < mMetaClassSect.s.addr + mMetaClassSect.size)
	{
		thePtr	= (char*)((UInt32)mMetaClassSect.contents +
			(inAddr - mMetaClassSect.s.addr));

		if (outType)
			*outType	= OCClassType;
	}
/*	else	// (__OBJC,__instance_vars) (objc_method_list)
	if (inAddr >= mIVarSect.s.addr &&
		inAddr < mIVarSect.s.addr + mIVarSect.size)
	{
		thePtr	= (mIVarSect.contents + (inAddr - mIVarSect.s.addr));
	}*/
	else	// (__OBJC,__module_info) (objc_module)
	if (inAddr >= mObjcModSect.s.addr &&
		inAddr < mObjcModSect.s.addr + mObjcModSect.size)
	{
		thePtr	= (char*)((UInt32)mObjcModSect.contents +
			(inAddr - mObjcModSect.s.addr));

		if (outType)
			*outType	= OCModType;
	}
/*	else	// (__OBJC,__symbols) (objc_symtab)
	if (inAddr >= mObjcSymSect.s.addr &&
		inAddr < mObjcSymSect.s.addr + mObjcSymSect.size)
	{
		thePtr	= (mObjcSymSect.contents + (inAddr - mObjcSymSect.s.addr));
	}*/

			//  (__OBJC, ??) (char*)
			// __message_refs, __class_refs, __instance_vars, __symbols
	for (i = 0; !thePtr && i < mNumObjcSects; i++)
	{
		if (inAddr >= mObjcSects[i].s.addr &&
			inAddr < mObjcSects[i].s.addr + mObjcSects[i].size)
		{
			thePtr	= (char*)(mObjcSects[i].contents +
				(inAddr - mObjcSects[i].s.addr));

			if (outType)
				*outType	= OCGenericType;
		}
	}

	if (thePtr)
		return thePtr;

			// (__IMPORT,__pointers) (cf_string_object*)
	if (inAddr >= mImpPtrSect.s.addr &&
		inAddr < mImpPtrSect.s.addr + mImpPtrSect.size)
	{
		thePtr	= (char*)((UInt32)mImpPtrSect.contents +
			(inAddr - mImpPtrSect.s.addr));

		if (outType)
			*outType	= ImpPtrType;
	}

	if (thePtr)
		return thePtr;

			// (__DATA,__data) (char**)
	if (inAddr >= mDataSect.s.addr &&
		inAddr < mDataSect.s.addr + mDataSect.size)
	{
		thePtr	= (char*)(mDataSect.contents + (inAddr - mDataSect.s.addr));

		UInt8	theType		= DataGenericType;
		UInt32	theValue	= *(UInt32*)thePtr;

		if (mSwapped)
			theValue	= OSSwapInt32(theValue);

		if (theValue != 0)
		{
			theType	= PointerType;

			static	UInt32	recurseCount	= 0;

			while (theType == PointerType)
			{
				recurseCount++;

				if (recurseCount > 5)
				{
					theType	= DataGenericType;
					break;
				}

				thePtr	= GetPointer(theValue, &theType);

				if (!thePtr)
				{
					theType	= DataGenericType;
					break;
				}

				theValue	= *(UInt32*)thePtr;
			}

			recurseCount	= 0;
		}

		if (outType)
			*outType	= theType;
	}
	else	// (__DATA,__const) (void*)
	if (inAddr >= mConstDataSect.s.addr &&
		inAddr < mConstDataSect.s.addr + mConstDataSect.size)
	{
		thePtr	= (char*)((UInt32)mConstDataSect.contents +
			(inAddr - mConstDataSect.s.addr));

		if (outType)
		{
			UInt32	theID	= *(UInt32*)thePtr;

			if (mSwapped)
				theID	= OSSwapInt32(theID);

			if (theID == typeid_NSString)
				*outType	= OCStrObjectType;
			else
			{
				theID	= *(UInt32*)(thePtr + 4);

				if (mSwapped)
					theID	= OSSwapInt32(theID);

				if (theID == typeid_NSString)
					*outType	= CFStringType;
				else
					*outType	= DataConstType;
			}
		}
	}
	else	// (__DATA,__cfstring) (cf_string_object*)
	if (inAddr >= mCFStringSect.s.addr &&
		inAddr < mCFStringSect.s.addr + mCFStringSect.size)
	{
		thePtr	= (char*)((UInt32)mCFStringSect.contents +
			(inAddr - mCFStringSect.s.addr));

		if (outType)
			*outType	= CFStringType;
	}
	else	// (__DATA,__nl_symbol_ptr) (cf_string_object*)
	if (inAddr >= mNLSymSect.s.addr &&
		inAddr < mNLSymSect.s.addr + mNLSymSect.size)
	{
		thePtr	= (char*)((UInt32)mNLSymSect.contents +
			(inAddr - mNLSymSect.s.addr));

		if (outType)
			*outType	= NLSymType;
	}
	else	// (__DATA,__dyld) (function ptr)
	if (inAddr >= mDyldSect.s.addr &&
		inAddr < mDyldSect.s.addr + mDyldSect.size)
	{
		thePtr	= (char*)((UInt32)mDyldSect.contents +
			(inAddr - mDyldSect.s.addr));

		if (outType)
			*outType	= DYLDType;
	}
/*	else	// (__DATA,__la_symbol_ptr) (func ptr)
	if (inAddr >= mLASymSect.s.addr &&
		inAddr < mLASymSect.s.addr + mLASymSect.size)
	{
		thePtr	= (char*)((UInt32)mLASymSect.contents +
			(inAddr - mLASymSect.s.addr));

		if (outType)
			*outType	= LASymType;
	}
	else	// (__DATA,__la_sym_ptr2) (func ptr)
	if (inAddr >= mLASym2Sect.s.addr &&
		inAddr < mLASym2Sect.s.addr + mLASym2Sect.size)
	{
		thePtr	= (char*)((UInt32)mLASym2Sect.contents +
			(inAddr - mLASym2Sect.s.addr));

		if (outType)
			*outType	= LASymType;
	}*/

	// should implement these if they ever contain CFStrings or NSStrings
/*	else	// (__DATA, __coalesced_data) (?)
	if (localAddy >= mCoalDataSect.s.addr &&
		localAddy < mCoalDataSect.s.addr + mCoalDataSect.size)
	{
	}
	else	// (__DATA, __datacoal_nt) (?)
	if (localAddy >= mCoalDataNTSect.s.addr &&
		localAddy < mCoalDataNTSect.s.addr + mCoalDataNTSect.size)
	{
	}*/

	return thePtr;
}

#pragma mark -
#pragma mark Line list manipulators

// Each text line is stored in one element of a doubly-linked list. These are
// vanilla textbook funcs for maintaining the list.

//	insertLine:before:inList:
// ----------------------------------------------------------------------------

- (void)insertLine: (Line*)inLine
			before: (Line*)nextLine
			inList: (Line**)listHead
{
	if (!nextLine)
		return;

	if (nextLine == *listHead)
		*listHead	= inLine;

	inLine->prev	= nextLine->prev;
	inLine->next	= nextLine;
	nextLine->prev	= inLine;

	if (inLine->prev)
		inLine->prev->next	= inLine;
}

//	insertLine:after:inList:
// ----------------------------------------------------------------------------

- (void)insertLine: (Line*)inLine
			 after: (Line*)prevLine
			inList: (Line**)listHead
{
	if (!prevLine)
	{
		*listHead	= inLine;
		return;
	}

	inLine->next	= prevLine->next;
	inLine->prev	= prevLine;
	prevLine->next	= inLine;

	if (inLine->next)
		inLine->next->prev	= inLine;
}

//	replaceLine:withLine:inList:
// ----------------------------------------------------------------------------

- (void)replaceLine: (Line*)inLine
		   withLine: (Line*)newLine
			 inList: (Line**)listHead
{
	if (!inLine || !newLine)
		return;

	if (inLine == *listHead)
		*listHead	= newLine;

	newLine->next	= inLine->next;
	newLine->prev	= inLine->prev;

	if (newLine->next)
		newLine->next->prev	= newLine;

	if (newLine->prev)
		newLine->prev->next	= newLine;

	if (inLine->chars)
		free(inLine->chars);

	free(inLine);
}

//	printLinesFromList:
// ----------------------------------------------------------------------------

- (BOOL)printLinesFromList: (Line*)listHead
{
	const char*	outPath	= CSTRING(mOutputFilePath);
	Line*	theLine		= listHead;
	FILE*	outFile		= fopen(outPath, "w");

	if (!outFile)
	{
		perror("otx: unable to open output file");
		return false;
	}

	SInt32	fileNum	= fileno(outFile);

	while (theLine)
	{
		if (syscall(SYS_write, fileNum, theLine->chars, theLine->length) == -1)
		{
			perror("otx: unable to write to output file");

			if (fclose(outFile) != 0)
				perror("otx: unable to close output file");

			return false;
		}

		theLine	= theLine->next;
	}

	if (fclose(outFile) != 0)
	{
		perror("otx: unable to close output file");
		return false;
	}

	return true;
}

//	deleteLinesFromList:
// ----------------------------------------------------------------------------

- (void)deleteLinesFromList: (Line*)listHead;
{
	Line*	theLine	= listHead;

	while (theLine)
	{
		if (theLine->prev)				// if there's one behind us...
		{
			free(theLine->prev->chars);	// delete it
			free(theLine->prev);
		}

		if (theLine->next)				// if there are more...
			theLine	= theLine->next;	// jump to next one
		else
		{								// this is last one, delete it
			free(theLine->chars);
			free(theLine);
			theLine	= nil;
		}
	}
}

#pragma mark -
//	verifyNops:numFound:
// ----------------------------------------------------------------------------
//	Subclasses may override.

- (BOOL)verifyNops: (unsigned char***)outList
		  numFound: (UInt32*)outFound
{
	return false;
}

//	searchForNopsIn:ofLength:numFound:
// ----------------------------------------------------------------------------
//	Subclasses may override.
//	Return value is a newly allocated list of addresses of 'outFound' length.
//	Caller owns the list.

- (unsigned char**)searchForNopsIn: (unsigned char*)inHaystack
						  ofLength: (UInt32)inHaystackLength
						  numFound: (UInt32*)outFound
{
	return nil;
}

//	fixNops:toPath:
// ----------------------------------------------------------------------------
//	Subclasses may override.

- (NSURL*)fixNops: (NopList*)inList
		   toPath: (NSString*)inOutputFilePath
{
	return nil;
}

#pragma mark -
//	speedyDelivery
// ----------------------------------------------------------------------------

- (void)speedyDelivery
{
	GetDescription				= GetDescriptionFuncType
		[self methodForSelector: GetDescriptionSel];
	LineIsCode					= LineIsCodeFuncType
		[self methodForSelector: LineIsCodeSel];
	LineIsFunction				= LineIsFunctionFuncType
		[self methodForSelector: LineIsFunctionSel];
	AddressFromLine				= AddressFromLineFuncType
		[self methodForSelector: AddressFromLineSel];
	CodeFromLine				= CodeFromLineFuncType
		[self methodForSelector: CodeFromLineSel];
	CheckThunk					= CheckThunkFuncType
		[self methodForSelector: CheckThunkSel];
	ProcessLine					= ProcessLineFuncType
		[self methodForSelector: ProcessLineSel];
	ProcessCodeLine				= ProcessCodeLineFuncType
		[self methodForSelector: ProcessCodeLineSel];
	PostProcessCodeLine			= PostProcessCodeLineFuncType
		[self methodForSelector: PostProcessCodeLineSel];
	ChooseLine					= ChooseLineFuncType
		[self methodForSelector: ChooseLineSel];
	EntabLine					= EntabLineFuncType
		[self methodForSelector: EntabLineSel];
	GetPointer					= GetPointerFuncType
		[self methodForSelector: GetPointerSel];
	CommentForLine				= CommentForLineFuncType
		[self methodForSelector: CommentForLineSel];
	CommentForSystemCall		= CommentForSystemCallFuncType
		[self methodForSelector: CommentForSystemCallSel];
	UpdateRegisters				= UpdateRegistersFuncType
		[self methodForSelector: UpdateRegistersSel];
	PrepareNameForDemangling	= PrepareNameForDemanglingFuncType
		[self methodForSelector: PrepareNameForDemanglingSel];
	ObjcClassPtrFromMethod		= ObjcClassPtrFromMethodFuncType
		[self methodForSelector: ObjcClassPtrFromMethodSel];
	ObjcCatPtrFromMethod		= ObjcCatPtrFromMethodFuncType
		[self methodForSelector: ObjcCatPtrFromMethodSel];
	ObjcMethodFromAddress		= ObjcMethodFromAddressFuncType
		[self methodForSelector: ObjcMethodFromAddressSel];
	ObjcClassFromName			= ObjcClassFromNameFuncType
		[self methodForSelector: ObjcClassFromNameSel];
	ObjcDescriptionFromObject	= ObjcDescriptionFromObjectFuncType
		[self methodForSelector: ObjcDescriptionFromObjectSel];
	InsertLineBefore			= InsertLineBeforeFuncType
		[self methodForSelector: InsertLineBeforeSel];
	InsertLineAfter				= InsertLineAfterFuncType
		[self methodForSelector: InsertLineAfterSel];
	ReplaceLine					= ReplaceLineFuncType
		[self methodForSelector: ReplaceLineSel];
	FindIvar					= FindIvarFuncType
		[self methodForSelector: FindIvarSel];
	FindSymbolByAddress			= FindSymbolByAddressFuncType
		[self methodForSelector: FindSymbolByAddressSel];
	FindClassMethodByAddress	= FindClassMethodByAddressFuncType
		[self methodForSelector: FindClassMethodByAddressSel];
	FindCatMethodByAddress		= FindCatMethodByAddressFuncType
		[self methodForSelector: FindCatMethodByAddressSel];
}

//	printSymbol:
// ----------------------------------------------------------------------------
//	Originally used for symbol debugging, may come in handy.

- (void)printSymbol: (nlist)inSym
{
	printf("----------------\n\n");
	printf(" n_strx = 0x%08x\n", inSym.n_un.n_strx);
	printf(" n_type = 0x%02x\n", inSym.n_type);
	printf(" n_sect = 0x%02x\n", inSym.n_sect);
	printf(" n_desc = 0x%04x\n", inSym.n_desc);
	printf("n_value = 0x%08x (%u)\n\n", inSym.n_value, inSym.n_value);

	if ((inSym.n_type & N_STAB) != 0)
	{	// too complicated, see <mach-o/stab.h>
		printf("STAB symbol\n");
	}
	else	// not a STAB
	{
		if ((inSym.n_type & N_PEXT) != 0)
			printf("Private external symbol\n\n");
		else if ((inSym.n_type & N_EXT) != 0)
			printf("External symbol\n\n");

		UInt8	theNType	= inSym.n_type & N_TYPE;
		UInt16	theRefType	= inSym.n_desc & REFERENCE_TYPE;

		printf("Symbol type: ");

		if (theNType == N_ABS)
			printf("Absolute\n");
		else if (theNType == N_SECT)
			printf("Defined in section %u\n", inSym.n_sect);
		else if (theNType == N_INDR)
			printf("Indirect\n");
		else
		{
			if (theNType == N_UNDF)
				printf("Undefined\n");
			else if (theNType == N_PBUD)
				printf("Prebound undefined\n");

			switch (theRefType)
			{
				case REFERENCE_FLAG_UNDEFINED_NON_LAZY:
					printf("REFERENCE_FLAG_UNDEFINED_NON_LAZY\n");
					break;
				case REFERENCE_FLAG_UNDEFINED_LAZY:
					printf("REFERENCE_FLAG_UNDEFINED_LAZY\n");
					break;
				case REFERENCE_FLAG_DEFINED:
					printf("REFERENCE_FLAG_DEFINED\n");
					break;
				case REFERENCE_FLAG_PRIVATE_DEFINED:
					printf("REFERENCE_FLAG_PRIVATE_DEFINED\n");
					break;
				case REFERENCE_FLAG_PRIVATE_UNDEFINED_NON_LAZY:
					printf("REFERENCE_FLAG_PRIVATE_UNDEFINED_NON_LAZY\n");
					break;
				case REFERENCE_FLAG_PRIVATE_UNDEFINED_LAZY:
					printf("REFERENCE_FLAG_PRIVATE_UNDEFINED_LAZY\n");
					break;

				default:
					break;
			}
		}
	}

	printf("\n");
}

@end
