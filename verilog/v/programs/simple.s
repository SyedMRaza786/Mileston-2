/*
    TEST PROGRAM #1: copy memory contents of 16 elements starting at
                     address 0x1000 over to starting address 0x1100.


    long output[16];

    void
    main(void)
    {
      long i;
      *a = 0x1000;
          *b = 0x1100;

      for (i=0; i < 16; i++)
        {
          a[i] = i*10;
          b[i] = a[i];
        }
    }
*/
    data = 0x1000
	li	x6, 0
	addi	x1, x2, 0x3
	addi	x4, x5, 0x6
	addi	x7, x8, 0x10
    wfi
