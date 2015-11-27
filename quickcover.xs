#define PERL_NO_GET_CONTEXT     /* we want efficiency */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "glog.h"
#include "cover.h"

#define QC_DIRECTORY "/tmp"
#define QC_PREFIX    "QC"
#define QC_EXTENSION ".txt"

static CoverList* cover = 0;

static void qc_install(pTHX);
static void qc_uninstall(pTHX);
static OP*  qc_nextstate(pTHX);

static Perl_ppaddr_t nextstate_orig = 0;

static void qc_install(pTHX) {
    if ( PL_ppaddr[OP_NEXTSTATE] == qc_nextstate) {
        die("QuickCover internal error, exiting: qc_install probably called twice in a row ");
        exit(EXIT_FAILURE);
    }

    /* If necessary, create cover data repository */
    if (!cover) {
        cover = cover_create();
        GLOG(("qc_install: created cover data is [%p]", cover));
    }

    nextstate_orig = PL_ppaddr[OP_NEXTSTATE];
    PL_ppaddr[OP_NEXTSTATE] = qc_nextstate;


    GLOG(("qc_install: nextstate_orig     is [%p]\n"
          "                  qc_nextstate is [%p]\n",
          nextstate_orig, qc_nextstate));
}

static void qc_uninstall(pTHX) {
    if ( PL_ppaddr[OP_NEXTSTATE] != qc_nextstate) {
        die("QuickCover internal error, exiting: qc_uninstall probably called twice in a row ");
        exit(EXIT_FAILURE);
    }

    PL_ppaddr[OP_NEXTSTATE] = nextstate_orig;
    GLOG(("qc_uninstall: nextstate reset to [%p]", nextstate_orig));
}

static OP* qc_nextstate(pTHX) {
    OP* ret = 0;


    GLOG(("I'm still running\n"));
    /* Restore original PP function for speed, already tracked this location. */
    PL_op->op_ppaddr = nextstate_orig;

    /* Call original PP function */
    ret = nextstate_orig(aTHX);

    /* Now do our own nefarious tracking... */
    cover_add(cover, CopFILE(PL_curcop), CopLINE(PL_curcop));

    return ret;
}

static void qc_dump(CoverList *cover) {
    static int count = 0;
    static time_t last = 0;

    assert(cover);

    time_t t = time(0);
    FILE* fp = 0;
    char base[1024];
    char tmp[1024];
    char txt[1024];
    struct tm now;

    if (!cover) {
        GLOG(("qc_dump: no cover data"));
        return;
    }

    /*
     * If current time is different from last time (seconds resolution), reset
     * file suffix counter to zero.
     */
    if (last != t) {
        last = t;
        count = 0;
    }

    /*
     * Get detailed current time:
     */
    localtime_r(&t, &now);

    /*
     * We generate the information on a file with the following structure:
     *
     *   dir/prefix_YYYYMMDD_hhmmss_pid_NNNNN.txt
     *
     * where NNNNN is a suffix counter to allow for more than one file in a
     * single second interval.
     */
    sprintf(base, "%s_%04d%02d%02d_%02d%02d%02d_%ld_%05d",
            QC_PREFIX,
            now.tm_year + 1900, now.tm_mon + 1, now.tm_mday,
            now.tm_hour, now.tm_min, now.tm_sec,
            (long) getpid(),
            count++);

    /*
     * We generate the information on a file with a prepended dot.  Once we are
     * done, we atomically rename it and get rid of the dot.  This way, any job
     * polling for new files will not find any half-done work.
     */
    sprintf(tmp, "%s/.%s%s", QC_DIRECTORY, base, QC_EXTENSION);
    sprintf(txt, "%s/%s%s" , QC_DIRECTORY, base, QC_EXTENSION);
    GLOG(("qc_dump: dumping cover data [%p] to file [%s]", cover, txt));
    fp = fopen(tmp, "w");
    if (!fp) {
        GLOG(("qc_dump: could not create dump file [%s]", tmp));
    } else {
        cover_dump(cover, fp, &now);
        fclose(fp);
        rename(tmp, txt);
    }

    GLOG(("qc_dump: deleting cover data [%p]", cover));
}




MODULE = Devel::QuickCover        PACKAGE = Devel::QuickCover
PROTOTYPES: DISABLE

#################################################################

void
start()
CODE:
    GLOG(("@@@ start()"));
    if (PL_ppaddr[OP_NEXTSTATE] == qc_nextstate) {
        croak("Devel::QuickCover::end() must be called before calling Devel::Quickcover::start() again.");
    } else {
        qc_install(aTHX);
    }

void
end()
CODE:
    GLOG(("@@@ end()"));
    if (PL_ppaddr[OP_NEXTSTATE] != qc_nextstate) {
        croak("Devel::QuickCover::start() must be called before calling Devel::Quickcover::end()");
    } else {
        qc_uninstall(aTHX);
        qc_dump(cover);
        cover_destroy(&cover);
    }
